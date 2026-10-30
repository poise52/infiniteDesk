use std::{ffi::OsString, path::PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Scenario {
    Sparse,
    Dense,
    FitAll,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Demo,
    Benchmark,
    Microbench,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    pub windows: usize,
    pub seed: u64,
    pub focus: Option<u64>,
    pub mode: Mode,
    pub duration: u64,
    pub warmup: u64,
    pub output: Option<PathBuf>,
    pub scenario: Scenario,
    pub target_hz: u32,
}
#[derive(Debug, PartialEq, Eq)]
pub enum Command {
    Run(Options),
    Help,
}
pub const HELP: &str = "InfiniteDesk\n\nUsage: desk-app [--demo|--benchmark|--microbench] [--windows 100|1000|5000|10000] [--seed N] [--focus ID] [--duration SECONDS] [--warmup SECONDS] [--scenario sparse|dense|fit-all] [--target-hz HZ] [--output PATH]\n\nBenchmark duration: 1..=600 s; warmup: 0..=60 s; target-hz: 10..=1000 (reference, not measured refresh).\n";

#[allow(clippy::too_many_lines)]
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<Command, String> {
    let mut options = Options {
        windows: 1000,
        seed: 42,
        focus: None,
        mode: Mode::Demo,
        duration: 30,
        warmup: 3,
        output: None,
        scenario: Scenario::Sparse,
        target_hz: 60,
    };
    let mut mode = None;
    let mut benchmark_option = false;
    let mut timing_option = false;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let arg = arg
            .into_string()
            .map_err(|_| "arguments must be valid UTF-8".to_owned())?;
        match arg.as_str() {
            "--demo" | "--benchmark" | "--microbench" => {
                let next = match arg.as_str() {
                    "--benchmark" => Mode::Benchmark,
                    "--microbench" => Mode::Microbench,
                    _ => Mode::Demo,
                };
                if mode.is_some_and(|previous| previous != next) {
                    return Err(
                        "--demo, --benchmark and --microbench are mutually exclusive".into(),
                    );
                }
                mode = Some(next);
                options.mode = next;
            }
            "-h" | "--help" => return Ok(Command::Help),
            "--windows" | "--seed" | "--focus" | "--duration" | "--warmup" | "--target-hz"
            | "--scenario" | "--output" => {
                let value = args
                    .next()
                    .ok_or_else(|| format!("{arg} requires a value"))?;
                if arg == "--output" {
                    if value.is_empty() {
                        return Err("--output must not be empty".into());
                    }
                    options.output = Some(value.into());
                    benchmark_option = true;
                    continue;
                }
                let value = value
                    .into_string()
                    .map_err(|_| format!("invalid {arg} value"))?;
                match arg.as_str() {
                    "--windows" => {
                        options.windows = value.parse().map_err(|_| "invalid --windows")?;
                        if ![100, 1000, 5000, 10_000].contains(&options.windows) {
                            return Err("--windows must be 100, 1000, 5000, or 10000; zero is not a demo scene".into());
                        }
                    }
                    "--seed" => options.seed = value.parse().map_err(|_| "invalid --seed")?,
                    "--focus" => {
                        options.focus = Some(value.parse().map_err(|_| "invalid --focus")?);
                    }
                    "--duration" => {
                        options.duration = value.parse().map_err(|_| "invalid --duration")?;
                        benchmark_option = true;
                        timing_option = true;
                    }
                    "--warmup" => {
                        options.warmup = value.parse().map_err(|_| "invalid --warmup")?;
                        benchmark_option = true;
                        timing_option = true;
                    }
                    "--target-hz" => {
                        options.target_hz = value.parse().map_err(|_| "invalid --target-hz")?;
                        benchmark_option = true;
                        timing_option = true;
                    }
                    "--scenario" => {
                        options.scenario = match value.as_str() {
                            "sparse" => Scenario::Sparse,
                            "dense" => Scenario::Dense,
                            "fit-all" => Scenario::FitAll,
                            _ => return Err("--scenario must be sparse, dense, or fit-all".into()),
                        };
                        benchmark_option = true;
                    }
                    _ => return Err(format!("unknown argument: {arg}")),
                }
            }
            _ => return Err(format!("unknown argument: {arg}")),
        }
    }
    if options
        .focus
        .is_some_and(|id| usize::try_from(id).map_or(true, |index| index >= options.windows))
    {
        return Err(format!(
            "--focus ID must be between 0 and {}",
            options.windows - 1
        ));
    }
    if !(1..=600).contains(&options.duration)
        || options.warmup > 60
        || !(10..=1000).contains(&options.target_hz)
    {
        return Err("duration, warmup or target-hz outside supported range".into());
    }
    if options.mode == Mode::Demo && benchmark_option {
        return Err("benchmark options require --benchmark or --microbench".into());
    }
    if options.mode == Mode::Microbench && timing_option {
        return Err("--duration, --warmup and --target-hz require --benchmark".into());
    }
    if options.mode != Mode::Demo && options.focus.is_some() {
        return Err("--focus is available only with --demo".into());
    }
    Ok(Command::Run(options))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }
    #[test]
    fn rejects_invalid_and_accepts_valid_options() {
        assert_eq!(parse(args(&["--help"])), Ok(Command::Help));
        for values in [
            &["--windows", "0"][..],
            &["--windows", "101"],
            &["--seed", "-1"],
            &["--windows"],
            &["--other"],
            &["--focus", "100", "--windows", "100"],
            &["--focus", "-1"],
            &["--focus"],
            &["--benchmark", "--demo"],
            &["--benchmark", "--duration", "0"],
            &["--benchmark", "--duration", "NaN"],
            &["--benchmark", "--warmup", "61"],
            &["--benchmark", "--target-hz", "0"],
            &["--scenario", "dense"],
            &["--microbench", "--duration", "10"],
        ] {
            assert!(parse(args(values)).is_err(), "{values:?}");
        }
        let Ok(Command::Run(options)) = parse(args(&["--focus", "9999", "--windows", "10000"]))
        else {
            panic!("valid args rejected")
        };
        assert_eq!(options.focus, Some(9999));
        let Ok(Command::Run(options)) = parse(args(&[
            "--warmup",
            "0",
            "--benchmark",
            "--scenario",
            "dense",
        ])) else {
            panic!("valid args rejected")
        };
        assert_eq!(options.scenario, Scenario::Dense);
    }
}
