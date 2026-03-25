mod dump;
mod report;
mod unwind;
mod symbols;

use anyhow::Result;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: {} <dump.bin> <game.elf>", args[0].as_str());
        std::process::exit(1);
    }

    let dump = dump::CrashDump::from_file(&args[1])?;
    let sym = symbols::SymbolResolver::load(&args[2])?;
    report::print_report(&dump, &sym);
    Ok(())
}
