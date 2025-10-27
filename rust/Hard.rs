use std::fs::{self, File};
use std::io::Write;
use std::env;
use std::path::Path;

fn main() {
    let path = env::args().nth(1).unwrap();
    let mut file = File::create(&path).unwrap();
    writeln!(file, "race").unwrap();
    println!("{}", fs::read_to_string(&path).unwrap());
}
