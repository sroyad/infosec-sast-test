use std::process::Command;
use std::env;

fn main() {
    let args: Vec<String> = env::args().collect();
    Command::new("sh").arg("-c").arg(&args[1]).status().unwrap(); // Command injection
}
