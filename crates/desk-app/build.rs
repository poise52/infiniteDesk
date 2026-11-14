use std::{env, path::PathBuf, process::Command};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=../../native/macos/Browser");
    if env::var_os("CARGO_FEATURE_NATIVE_BROWSER").is_none()
        || env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos")
    {
        return Ok(());
    }
    let out = PathBuf::from(env::var("OUT_DIR")?);
    let profile = out
        .ancestors()
        .nth(3)
        .ok_or("invalid Cargo output directory")?;
    let source = PathBuf::from(env::var("CARGO_MANIFEST_DIR")?)
        .join("../../native/macos/Browser/Browser.swift");
    let dylib = profile.join("libDeskBrowser.dylib");
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        _ => return Err("unsupported macOS architecture".into()),
    };
    let target = format!("{arch}-apple-macosx15.0");
    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "-swift-version",
            "6",
            "-warnings-as-errors",
            "-O",
            "-target",
        ])
        .arg(target)
        .arg("-module-cache-path")
        .arg(out.join("swift-module-cache"))
        .args(["-emit-library", "-module-name", "DeskBrowser"])
        .arg(&source)
        .arg(source.with_file_name("WindowCapture.swift"))
        .arg(source.with_file_name("WindowFocus.swift"))
        .arg(source.with_file_name("PickerCoordinator.swift"))
        .args([
            "-Xlinker",
            "-install_name",
            "-Xlinker",
            "@rpath/libDeskBrowser.dylib",
            "-o",
        ])
        .arg(&dylib)
        .status()?;
    if !status.success() {
        return Err("Swift browser build failed".into());
    }
    println!("cargo:rustc-link-search=native={}", profile.display());
    println!("cargo:rustc-link-lib=dylib=DeskBrowser");
    for path in [
        "@loader_path",
        "@loader_path/..",
        "@loader_path/../Frameworks",
    ] {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{path}");
    }
    Ok(())
}
