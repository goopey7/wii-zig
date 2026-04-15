use crate::{
    dump::CrashDump,
    symbols::{ResolvedFrame, SymbolResolver},
    unwind::unwind as unwind_abi,
    unwind_dwarf::unwind_dwarf,
};

const RESET: &str = "\x1b[0m";
const YELLOW: &str = "\x1b[33m";

pub fn print_report(dump: &CrashDump, sym: &SymbolResolver, elf_data: &[u8]) {
    println!("exception: {} ({:#x})", dump.exid.name(), dump.exid as u32);
    println!(
        "pc={:#010x} lr={:#010x} ctr={:#010x}",
        dump.pc, dump.lr, dump.ctr
    );
    println!(
        "msr={:#010x} xer={:#010x} cr={:#010x}",
        dump.msr, dump.xer, dump.cr
    );
    println!();

    println!("gprs:");
    for row in 0..8 {
        let i = row * 4;
        println!(
            "  r{:02}={:08x}  r{:02}={:08x}  r{:02}={:08x}  r{:02}={:08x}",
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

    println!("stack trace (abi):");
    let abi_frames = unwind_abi(dump);
    for (i, &addr) in abi_frames.iter().enumerate() {
        print_frame(i, &sym.resolve(addr as u64));
    }
    println!();

    let dwarf_result = unwind_dwarf(dump, elf_data);
    println!("stack trace (dwarf cfi):");

    if let Some(ref e) = dwarf_result.error {
        println!("  {}warning: {}{}", YELLOW, e, RESET);
    }
    for (i, &addr) in dwarf_result.frames.iter().enumerate() {
        print_frame(i, &sym.resolve(addr as u64));
    }
    println!();
}

fn print_frame(idx: usize, f: &ResolvedFrame) {
    let func = f.function.as_deref().unwrap_or("???");
    match (&f.file, f.line) {
        (Some(file), Some(line)) => println!(
            "  {} {:#010x}  {}  ({}{}:{}{} )",
            idx, f.addr, func, YELLOW, file, line, RESET
        ),
        _ => println!("  {} {:#010x}  {}", idx, f.addr, func),
    }

    for sl in &f.source_context {
        let marker = if sl.is_crash_line { ">" } else { " " };
        let color = if sl.is_crash_line { YELLOW } else { "" };
        println!(
            "      {}{} {:4}  {}{}",
            marker, color, sl.line_num, sl.text, RESET
        );
    }

    for inlined in &f.inlined {
        println!("             inlined: {}", inlined);
    }
}
