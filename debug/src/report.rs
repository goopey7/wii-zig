use crate::{dump::CrashDump, symbols::{ResolvedFrame, SymbolResolver}, unwind::unwind};

pub fn print_report(dump: &CrashDump, sym: &SymbolResolver) {
    println!(
        "Exception : {} (0x{:05X})",
        dump.exid.name(),
        dump.exid as u32
    );
    println!("PC        : 0x{:08X}", dump.pc);
    println!("LR        : 0x{:08X}", dump.lr);
    println!("CTR       : 0x{:08X}", dump.ctr);
    println!("MSR       : 0x{:08X}", dump.msr);
    println!("XER       : 0x{:08X}", dump.xer);
    println!("CR        : 0x{:08X}", dump.cr);
    println!();

    println!("General Purpose Registers:");
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

    println!("Stack Trace:");
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
            "  #{:<2}  0x{:08X}  {}  ({}:{})",
            idx, f.addr, func, file, line
        ),
        _ => println!("  #{:<2}  0x{:08X}  {}", idx, f.addr, func),
    }
    for inlined in &f.inlined {
        println!("             (inlined) {}", inlined);
    }
}
