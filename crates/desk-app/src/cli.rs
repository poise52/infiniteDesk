use std::ffi::OsString;

#[derive(Debug, PartialEq, Eq)]
pub struct Options {
    pub windows: usize,
    pub seed: u64,
    pub focus: Option<u64>,
}
#[derive(Debug, PartialEq, Eq)]
pub enum Command {
    Run(Options),
    Help,
}

pub const HELP: &str = "InfiniteDesk demo\n\nUsage: desk-app [--demo] [--windows 100|1000|5000|10000] [--seed N] [--focus ID]\n\nOptions:\n  --demo        Run the virtual-window demo (default)\n  --windows N   Number of windows (default: 1000)\n  --seed N      Deterministic scene seed (default: 42)\n  --focus ID    Select and center a window by ID\n  -h, --help    Show this help\n";

pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<Command, String> {
    let mut options = Options {
        windows: 1000,
        seed: 42,
        focus: None,
    };
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let arg = arg
            .into_string()
            .map_err(|_| "arguments must be valid UTF-8".to_owned())?;
        match arg.as_str() {
            "--demo" => {}
            "-h" | "--help" => return Ok(Command::Help),
            "--windows" => {
                let value = args
                    .next()
                    .ok_or("--windows requires a value")?
                    .into_string()
                    .map_err(|_| "invalid --windows value")?;
                options.windows = value
                    .parse()
                    .map_err(|_| "--windows must be 100, 1000, 5000, or 10000")?;
                if ![100, 1000, 5000, 10_000].contains(&options.windows) {
                    return Err(
                        "--windows must be 100, 1000, 5000, or 10000; zero is not a demo scene"
                            .into(),
                    );
                }
            }
            "--focus" => {
                let value = args
                    .next()
                    .ok_or("--focus requires a value")?
                    .into_string()
                    .map_err(|_| "invalid --focus value")?;
                options.focus = Some(
                    value
                        .parse()
                        .map_err(|_| "--focus must be an unsigned 64-bit window ID")?,
                );
            }
            "--seed" => {
                let value = args
                    .next()
                    .ok_or("--seed requires a value")?
                    .into_string()
                    .map_err(|_| "invalid --seed value")?;
                options.seed = value
                    .parse()
                    .map_err(|_| "--seed must be an unsigned 64-bit integer")?;
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
    Ok(Command::Run(options))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }
    #[test]
    fn parses_supported_and_rejects_invalid_options() {
        assert_eq!(
            parse(args(&["--demo", "--windows", "10000", "--seed", "7"])),
            Ok(Command::Run(Options {
                windows: 10000,
                seed: 7,
                focus: None,
            }))
        );
        assert_eq!(parse(args(&["--help"])), Ok(Command::Help));
        assert!(parse(args(&["--windows", "0"])).is_err());
        assert!(parse(args(&["--windows", "101"])).is_err());
        assert!(parse(args(&["--seed", "-1"])).is_err());
        assert!(parse(args(&["--windows"])).is_err());
        assert!(parse(args(&["--other"])).is_err());
        assert_eq!(
            parse(args(&["--focus", "9999", "--windows", "10000"])),
            Ok(Command::Run(Options {
                windows: 10000,
                seed: 42,
                focus: Some(9999)
            }))
        );
        assert!(parse(args(&["--focus", "100", "--windows", "100"])).is_err());
        assert!(parse(args(&["--windows", "100", "--focus", "-1"])).is_err());
        assert!(parse(args(&["--focus"])).is_err());
    }
}
