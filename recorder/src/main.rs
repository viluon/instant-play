#![deny(rust_2018_idioms)]
#![allow(unsafe_op_in_unsafe_fn)]

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs::{File, OpenOptions};
use std::io::{self, BufWriter};
use std::process::exit;
use std::sync::Mutex;

#[macro_use]
extern crate log;

mod coalesce;
mod libc_extras;
mod libc_wrappers;
mod passthrough;

struct StderrLogger;

impl log::Log for StderrLogger {
    fn enabled(&self, m: &log::Metadata<'_>) -> bool {
        m.level() <= log::Level::Warn
    }
    fn log(&self, record: &log::Record<'_>) {
        if self.enabled(record.metadata()) {
            eprintln!("{}: {}", record.level(), record.args());
        }
    }
    fn flush(&self) {}
}

static LOGGER: StderrLogger = StderrLogger;

fn usage() -> ! {
    eprintln!("usage: recorder mount <store> <mountpoint> <logfile>");
    eprintln!("       recorder coalesce <logfile> [allowed-paths]");
    exit(2);
}

fn main() {
    log::set_logger(&LOGGER).unwrap();
    log::set_max_level(log::LevelFilter::Warn);

    let args: Vec<OsString> = env::args_os().collect();
    match args.get(1).and_then(|a| a.to_str()) {
        Some("mount") if args.len() == 5 => {
            let logf = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&args[4])
                .expect("open logfile");
            let fs = passthrough::PassthroughFS {
                target: args[2].clone(),
                log: Mutex::new(BufWriter::new(logf)),
            };
            let opts = [OsStr::new("-o"), OsStr::new("fsname=ip-recorder,ro")];
            fuse_mt::mount(fuse_mt::FuseMT::new(fs, 1), &args[3], &opts).unwrap();
        }
        Some("coalesce") if args.len() == 3 || args.len() == 4 => {
            let allowed = args.get(3).map(|p| {
                std::fs::read_to_string(p)
                    .expect("read allowed-paths")
                    .lines()
                    .map(str::to_string)
                    .collect::<std::collections::HashSet<_>>()
            });
            let f = File::open(&args[2]).expect("open logfile");
            let profile =
                coalesce::coalesce(io::BufReader::new(f), allowed.as_ref()).expect("read log");
            let out = io::stdout();
            coalesce::write_json(&mut out.lock(), &profile).expect("write json");
        }
        _ => usage(),
    }
}
