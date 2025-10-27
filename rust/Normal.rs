use std::fs;
use std::env;

fn main() {
    let filename = env::args().nth(1).unwrap();
    let content = fs::read_to_string(filename).unwrap();
    println!("{}", content);
}
