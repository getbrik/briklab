use rust_complete::{add, divide, multiply, subtract};

fn main() {
    println!("Calculator demo:");
    println!("  2 + 3 = {}", add(2, 3));
    println!("  4 * 5 = {}", multiply(4, 5));
    println!("  10 - 3 = {}", subtract(10, 3));
    match divide(10, 3) {
        Ok(result) => println!("  10 / 3 = {:.2}", result),
        Err(e) => println!("  10 / 3 = error: {}", e),
    }
}
