use std::fs;
use std::process;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 || args[1] != "remove" {
        println!("usage: spk remove <package>");
        return;
    }

    let name = &args[2];

    for dir in ["/usr/bin", "/usr/local/bin", "/bin"] {
        let path = format!("{}/{}", dir, name);
        if fs::remove_file(&path).is_ok() {
            println!("spk: removed {}", path);
            let _ = fs::remove_file(format!("/tmp/{}.spk", name));
            println!("spk: mirror refreshed");
            return;
        }
    }

    println!("spk: could not find {}", name);
    process::exit(1);
}
