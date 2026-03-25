use crate::{
    dump::CrashDump,
    symbols::{ResolvedFrame, SymbolResolver},
    unwind::unwind,
};

const RESET: &str = "\x1b[0m";
const YELLOW: &str = "\x1b[33m";
const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";

pub fn print_report(dump: &CrashDump, sym: &SymbolResolver) {
    println!(
        "{}Exception : {} (0x{:05X}){}",
        BOLD,
        dump.exid.name(),
        dump.exid as u32,
        RESET
    );
    println!("{}PC{}        : 0x{:08X}", BOLD, RESET, dump.pc);
    println!("{}LR{}        : 0x{:08X}", BOLD, RESET, dump.lr);
    println!("{}CTR{}       : 0x{:08X}", BOLD, RESET, dump.ctr);
    println!("{}MSR{}       : 0x{:08X}", BOLD, RESET, dump.msr);
    println!("{}XER{}       : 0x{:08X}", BOLD, RESET, dump.xer);
    println!("{}CR{}        : 0x{:08X}", BOLD, RESET, dump.cr);
    println!();

    println!("{}General Purpose Registers:{}", BOLD, RESET);
    for row in 0..8 {
        let i = row * 4;
        println!(
            "  r{:02}={:08X}  r{:02}={:08X}  r{:02}={:08X}  r{:02}={:08X}",
            i,
            dump.gpr[i],
            i + 1,
            dump.gpr[i + 1],
            i + 2,
            dump.gpr[i + 2],
            i + 3,
            dump.gpr[i + 3],
        );
    }
    println!();

    println!("{}Stack Trace:{}", BOLD, RESET);
    let frames = unwind(dump);
    for (i, &addr) in frames.iter().enumerate() {
        let resolved = sym.resolve(addr as u64);
        print_frame(i, &resolved);
    }
}

fn print_frame(idx: usize, f: &ResolvedFrame) {
    let func = f.function.as_deref().unwrap_or("<unknown>");
    match (&f.file, f.line) {
        (Some(file), Some(line)) => println!(
            "  #{:<2}  0x{:08X}  {}  ({}{}:{}{})",
            idx, f.addr, func, YELLOW, file, RESET, line
        ),
        _ => println!("  #{:<2}  0x{:08X}  {}", idx, f.addr, func),
    }

    if !f.source_context.is_empty() {
        for sl in &f.source_context {
            let marker = if sl.is_crash_line { ">" } else { " " };
            let color = if sl.is_crash_line { YELLOW } else { DIM };
            let line_color = if sl.is_crash_line { YELLOW } else { RESET };
            println!(
                "      {}{}{:4}{}  {}{}{}",
                marker, color, sl.line_num, RESET, line_color, sl.text, RESET
            );
        }
    }

    for inlined in &f.inlined {
        println!("             {}inlined: {}{}", DIM, inlined, RESET);
    }
}
