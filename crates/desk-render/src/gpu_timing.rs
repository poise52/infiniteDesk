use std::{
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    },
    time::{Duration, Instant},
};

const SLOT_COUNT: usize = 8;
const QUERY_INDICES: [u32; SLOT_COUNT] = [0, 2, 4, 6, 8, 10, 12, 14];
const RESULT_LIMIT: usize = 200_000;
const FREE: u8 = 0;
const PENDING: u8 = 1;
const SAMPLED: u8 = 2;
const READY: u8 = 3;
const FAILED: u8 = 4;

#[derive(Debug)]
struct SlotState {
    frame_id: Option<u64>,
    callback: Arc<AtomicU8>,
}
impl SlotState {
    fn new() -> Self {
        Self {
            frame_id: None,
            callback: Arc::new(AtomicU8::new(FREE)),
        }
    }
    fn reserve(&mut self, frame_id: u64) -> bool {
        if self.frame_id.is_some() {
            return false;
        }
        self.frame_id = Some(frame_id);
        self.callback.store(PENDING, Ordering::Release);
        true
    }
    fn completion(&self) -> u8 {
        self.callback.load(Ordering::Acquire)
    }
    fn release(&mut self) -> Option<u64> {
        self.callback.store(FREE, Ordering::Release);
        self.frame_id.take()
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum InvalidTimestamp {
    Length,
    Period,
    ZeroStart,
    ZeroEnd,
    NonMonotonic,
    Equal,
    TooLarge,
}

#[allow(clippy::cast_precision_loss)]
fn duration_ms(bytes: &[u8], period_ns: f32) -> Result<f64, InvalidTimestamp> {
    if bytes.len() != 16 {
        return Err(InvalidTimestamp::Length);
    }
    if !period_ns.is_finite() || period_ns <= 0.0 {
        return Err(InvalidTimestamp::Period);
    }
    let start = u64::from_ne_bytes(
        bytes[..8]
            .try_into()
            .map_err(|_| InvalidTimestamp::Length)?,
    );
    let end = u64::from_ne_bytes(
        bytes[8..]
            .try_into()
            .map_err(|_| InvalidTimestamp::Length)?,
    );
    if start == 0 {
        return Err(InvalidTimestamp::ZeroStart);
    }
    if end == 0 {
        return Err(InvalidTimestamp::ZeroEnd);
    }
    let delta = end
        .checked_sub(start)
        .ok_or(InvalidTimestamp::NonMonotonic)?;
    if delta == 0 {
        return Err(InvalidTimestamp::Equal);
    }
    if delta > (1_u64 << 53) {
        return Err(InvalidTimestamp::TooLarge);
    }
    Ok(delta as f64 * f64::from(period_ns) / 1_000_000.0)
}
#[derive(Debug, serde::Serialize)]
pub struct InvalidExample {
    frame_id: Option<u64>,
    start: u64,
    end: u64,
    reason: InvalidTimestamp,
}

struct Slot {
    state: SlotState,
    buffer: wgpu::Buffer,
}
#[derive(Debug, Clone, serde::Serialize)]
pub struct GpuSample {
    pub frame_id: u64,
    pub render_pass_ms: f64,
}
#[derive(Debug, serde::Serialize)]
#[allow(clippy::struct_excessive_bools)]
pub struct GpuReport {
    pub requested: bool,
    pub supported: bool,
    pub enabled: bool,
    pub feature_enabled: bool,
    pub reason: Option<String>,
    pub queried_total: u64,
    pub skipped_ring_full_total: u64,
    pub map_errors_total: u64,
    pub invalid_timestamps_total: u64,
    pub invalid_examples: Vec<InvalidExample>,
    pub poll_errors_total: u64,
    pub sample_limit_skips_total: u64,
    pub sample_limit_discards_total: u64,
    pub pending_at_drain_end: usize,
    pub drain_timed_out: bool,
    pub period_ns: Option<f32>,
    pub ring_slots: usize,
    pub query_count: usize,
    pub resolve_buffer_bytes: u64,
    pub readback_buffer_count: usize,
    pub readback_buffer_bytes: u64,
    pub additional_buffer_count: usize,
    pub additional_logical_buffer_bytes: u64,
    pub sample_limit: usize,
    pub raw_gpu_vec_capacity_bytes: usize,
    pub raw_gpu_samples: Vec<GpuSample>,
}
impl GpuReport {
    #[must_use]
    pub fn unavailable(requested: bool, supported: bool, reason: &str) -> Self {
        Self {
            requested,
            supported,
            enabled: false,
            feature_enabled: requested && supported,
            reason: Some(reason.to_owned()),
            queried_total: 0,
            skipped_ring_full_total: 0,
            map_errors_total: 0,
            invalid_timestamps_total: 0,
            invalid_examples: Vec::new(),
            poll_errors_total: 0,
            sample_limit_skips_total: 0,
            sample_limit_discards_total: 0,
            pending_at_drain_end: 0,
            drain_timed_out: false,
            period_ns: None,
            ring_slots: 0,
            query_count: 0,
            resolve_buffer_bytes: 0,
            readback_buffer_count: 0,
            readback_buffer_bytes: 0,
            additional_buffer_count: 0,
            additional_logical_buffer_bytes: 0,
            sample_limit: RESULT_LIMIT,
            raw_gpu_vec_capacity_bytes: 0,
            raw_gpu_samples: Vec::new(),
        }
    }
}

pub struct GpuTimer {
    query: wgpu::QuerySet,
    resolve: wgpu::Buffer,
    slots: Vec<Slot>,
    period_ns: f32,
    disabled: bool,
    report: GpuReport,
}
impl GpuTimer {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Option<Self> {
        let period = queue.get_timestamp_period();
        if !period.is_finite() || period <= 0.0 {
            return None;
        }
        let query = device.create_query_set(&wgpu::QuerySetDescriptor {
            label: Some("canvas timestamps"),
            ty: wgpu::QueryType::Timestamp,
            count: 16,
        });
        let resolve = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("timestamp resolve"),
            size: SLOT_COUNT as u64 * wgpu::QUERY_RESOLVE_BUFFER_ALIGNMENT,
            usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let slots = (0..SLOT_COUNT)
            .map(|_| Slot {
                state: SlotState::new(),
                buffer: device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("timestamp readback"),
                    size: 16,
                    usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
                    mapped_at_creation: false,
                }),
            })
            .collect();
        Some(Self {
            query,
            resolve,
            slots,
            period_ns: period,
            disabled: false,
            report: GpuReport {
                requested: true,
                supported: true,
                enabled: true,
                feature_enabled: true,
                reason: None,
                queried_total: 0,
                skipped_ring_full_total: 0,
                map_errors_total: 0,
                invalid_timestamps_total: 0,
                invalid_examples: Vec::new(),
                poll_errors_total: 0,
                sample_limit_skips_total: 0,
                sample_limit_discards_total: 0,
                pending_at_drain_end: 0,
                drain_timed_out: false,
                period_ns: Some(period),
                ring_slots: SLOT_COUNT,
                query_count: SLOT_COUNT * 2,
                resolve_buffer_bytes: SLOT_COUNT as u64 * wgpu::QUERY_RESOLVE_BUFFER_ALIGNMENT,
                readback_buffer_count: SLOT_COUNT,
                readback_buffer_bytes: (SLOT_COUNT * 16) as u64,
                additional_buffer_count: SLOT_COUNT + 1,
                additional_logical_buffer_bytes: SLOT_COUNT as u64
                    * wgpu::QUERY_RESOLVE_BUFFER_ALIGNMENT
                    + (SLOT_COUNT * 16) as u64,
                sample_limit: RESULT_LIMIT,
                raw_gpu_vec_capacity_bytes: 0,
                raw_gpu_samples: Vec::new(),
            },
        })
    }
    pub fn reserve(&mut self, frame_id: u64) -> Option<usize> {
        if self.disabled {
            return None;
        }
        if self.report.raw_gpu_samples.len() >= RESULT_LIMIT {
            self.report.sample_limit_skips_total += 1;
            return None;
        }
        let Some(index) = self
            .slots
            .iter()
            .position(|slot| slot.state.frame_id.is_none())
        else {
            self.report.skipped_ring_full_total += 1;
            return None;
        };
        if self.slots[index].state.reserve(frame_id) {
            self.report.queried_total += 1;
            Some(index)
        } else {
            None
        }
    }
    pub const fn timestamp_writes(&self, slot: usize) -> wgpu::RenderPassTimestampWrites<'_> {
        let first = QUERY_INDICES[slot];
        wgpu::RenderPassTimestampWrites {
            query_set: &self.query,
            beginning_of_pass_write_index: Some(first),
            end_of_pass_write_index: Some(first + 1),
        }
    }
    pub fn submitted(&self, queue: &wgpu::Queue, slot: usize) {
        let callback = Arc::clone(&self.slots[slot].state.callback);
        queue.on_submitted_work_done(move || callback.store(SAMPLED, Ordering::Release));
    }
    fn encode_readback(&self, encoder: &mut wgpu::CommandEncoder, slot: usize) {
        let first = QUERY_INDICES[slot];
        let offset = slot as u64 * wgpu::QUERY_RESOLVE_BUFFER_ALIGNMENT;
        encoder.resolve_query_set(&self.query, first..first + 2, &self.resolve, offset);
        encoder.copy_buffer_to_buffer(&self.resolve, offset, &self.slots[slot].buffer, 0, 16);
        let callback = Arc::clone(&self.slots[slot].state.callback);
        encoder.map_buffer_on_submit(
            &self.slots[slot].buffer,
            wgpu::MapMode::Read,
            ..,
            move |result| {
                callback.store(
                    if result.is_ok() { READY } else { FAILED },
                    Ordering::Release,
                );
            },
        );
    }
    pub fn poll(&mut self, device: &wgpu::Device, queue: &wgpu::Queue) {
        if self.disabled {
            return;
        }
        if device.poll(wgpu::PollType::Poll).is_err() {
            self.report.poll_errors_total += 1;
            self.disabled = true;
            self.report.reason = Some("device polling failed".into());
        }
        self.collect();
        if self.disabled
            || !self
                .slots
                .iter()
                .any(|slot| slot.state.completion() == SAMPLED)
        {
            return;
        }
        // Metal counter resolves can race sampling. Wait for the render submission's
        // completion before submitting resolves; keep each query slot reserved until
        // its readback completes. See Dawn's Metal workaround: https://dawn.googlesource.com/dawn.git/+/f5fcc294c56511b3052afe928f0d37d1bdc9caeb%5E%21/.
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("timestamp resolve after sampling"),
        });
        for (index, slot) in self.slots.iter().enumerate() {
            if slot.state.completion() == SAMPLED {
                slot.state.callback.store(PENDING, Ordering::Release);
                self.encode_readback(&mut encoder, index);
            }
        }
        queue.submit([encoder.finish()]);
    }
    fn collect(&mut self) {
        for slot in &mut self.slots {
            let status = slot.state.completion();
            if status != READY && status != FAILED {
                continue;
            }
            if status == FAILED {
                self.report.map_errors_total += 1;
                slot.buffer.unmap();
                slot.state.release();
                continue;
            }
            let frame_id = slot.state.frame_id;
            let data = slot.buffer.get_mapped_range(..);
            match data {
                Ok(view) => match (duration_ms(&view, self.period_ns), frame_id) {
                    (Ok(value), Some(frame_id)) => {
                        if self.report.raw_gpu_samples.len() < RESULT_LIMIT {
                            self.report.raw_gpu_samples.push(GpuSample {
                                frame_id,
                                render_pass_ms: value,
                            });
                        } else {
                            self.report.sample_limit_discards_total += 1;
                        }
                    }
                    (Err(reason), _) => {
                        self.report.invalid_timestamps_total += 1;
                        if self.report.invalid_examples.len() < 8 && view.len() == 16 {
                            let start =
                                u64::from_ne_bytes(view[..8].try_into().unwrap_or_default());
                            let end = u64::from_ne_bytes(view[8..].try_into().unwrap_or_default());
                            self.report.invalid_examples.push(InvalidExample {
                                frame_id,
                                start,
                                end,
                                reason,
                            });
                        }
                    }
                    (Ok(_), None) => self.report.invalid_timestamps_total += 1,
                },
                _ => self.report.map_errors_total += 1,
            }
            slot.buffer.unmap();
            slot.state.release();
        }
    }
    pub fn drain(
        mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        timeout: Duration,
    ) -> GpuReport {
        let deadline = Instant::now() + timeout;
        while self.slots.iter().any(|slot| slot.state.frame_id.is_some())
            && Instant::now() < deadline
            && !self.disabled
        {
            self.poll(device, queue);
            if self.slots.iter().any(|slot| slot.state.frame_id.is_some()) {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        self.collect();
        self.report.pending_at_drain_end = self
            .slots
            .iter()
            .filter(|slot| slot.state.frame_id.is_some())
            .count();
        self.report.drain_timed_out =
            self.report.pending_at_drain_end > 0 && Instant::now() >= deadline;
        self.report.raw_gpu_vec_capacity_bytes =
            self.report.raw_gpu_samples.capacity() * std::mem::size_of::<GpuSample>();
        self.report
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn timestamps_reject_invalid_results() {
        let mut bytes = [0_u8; 16];
        bytes[..8].copy_from_slice(&10_u64.to_ne_bytes());
        bytes[8..].copy_from_slice(&1010_u64.to_ne_bytes());
        assert_eq!(duration_ms(&bytes, 2.0), Ok(0.002));
        assert_eq!(
            duration_ms(&bytes[..15], 1.0),
            Err(InvalidTimestamp::Length)
        );
        assert_eq!(duration_ms(&bytes, 0.0), Err(InvalidTimestamp::Period));
        assert_eq!(duration_ms(&bytes, f32::NAN), Err(InvalidTimestamp::Period));
        let mut zero_start = bytes;
        zero_start[..8].copy_from_slice(&0_u64.to_ne_bytes());
        assert_eq!(
            duration_ms(&zero_start, 1.0),
            Err(InvalidTimestamp::ZeroStart)
        );
        let mut large = bytes;
        large[8..].copy_from_slice(&((1_u64 << 53) + 11).to_ne_bytes());
        assert_eq!(duration_ms(&large, 1.0), Err(InvalidTimestamp::TooLarge));
        bytes[8..].copy_from_slice(&0_u64.to_ne_bytes());
        assert_eq!(duration_ms(&bytes, 1.0), Err(InvalidTimestamp::ZeroEnd));
        bytes[8..].copy_from_slice(&10_u64.to_ne_bytes());
        assert_eq!(duration_ms(&bytes, 1.0), Err(InvalidTimestamp::Equal));
        bytes[8..].copy_from_slice(&9_u64.to_ne_bytes());
        assert_eq!(
            duration_ms(&bytes, 1.0),
            Err(InvalidTimestamp::NonMonotonic)
        );
    }
    #[test]
    fn unsupported_feature_is_explicitly_unavailable() {
        let report = GpuReport::unavailable(true, false, "unsupported");
        assert!(report.requested);
        assert!(!report.supported && !report.enabled && !report.feature_enabled);
        assert_eq!(report.reason.as_deref(), Some("unsupported"));
        assert_eq!(report.additional_buffer_count, 0);
    }
    #[test]
    fn slot_reservation_and_callback_release_are_bounded() {
        let mut slots: Vec<_> = (0..SLOT_COUNT).map(|_| SlotState::new()).collect();
        for (i, slot) in slots.iter_mut().enumerate() {
            assert!(slot.reserve(i as u64));
            assert!(!slot.reserve(999));
        }
        assert!(slots.iter().all(|slot| slot.frame_id.is_some()));
        slots[3].callback.store(SAMPLED, Ordering::Release);
        assert_eq!(slots[3].completion(), SAMPLED);
        assert!(!slots[3].reserve(999));
        slots[3].callback.store(PENDING, Ordering::Release);
        assert!(!slots[3].reserve(999));
        slots[3].callback.store(READY, Ordering::Release);
        assert_eq!(slots[3].completion(), READY);
        assert_eq!(slots[3].release(), Some(3));
        assert!(slots[3].reserve(999));
        assert_eq!(slots[3].completion(), PENDING);
        slots[3].callback.store(SAMPLED, Ordering::Release);
        assert!(!slots[3].reserve(1000));
        slots[3].callback.store(PENDING, Ordering::Release);
        slots[3].callback.store(FAILED, Ordering::Release);
        assert_eq!(slots[3].completion(), FAILED);
        assert!(!slots[3].reserve(1000));
        assert_eq!(slots[3].release(), Some(999));
    }
}
