use crate::dump::CrashDump;
use gimli::{
    BaseAddresses, BigEndian, CieOrFde, EhFrame, EndianSlice, UnwindContext, UnwindSection,
};
use object::{Object, ObjectSection};

const DWARF_REG_R1: gimli::Register = gimli::Register(1);

#[derive(Debug, Clone)]
pub enum DwarfUnwindError {
    NoEhFrame,
    ParseError(String),
    NoFdeForPc(u32),
}

impl std::fmt::Display for DwarfUnwindError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoEhFrame => write!(f, "no .eh_frame section found in ELF"),
            Self::ParseError(msg) => write!(f, "CFI parse error: {}", msg),
            Self::NoFdeForPc(pc) => write!(f, "no FDE covers PC 0x{:08X}", pc),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CfiSource {
    EhFrame,
}

impl std::fmt::Display for CfiSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EhFrame => write!(f, ".eh_frame"),
        }
    }
}

pub struct DwarfUnwindResult {
    pub frames: Vec<u32>,
    pub cfi_source: Option<CfiSource>,
    pub error: Option<DwarfUnwindError>,
}

pub fn unwind_dwarf(dump: &CrashDump, elf_data: &[u8]) -> DwarfUnwindResult {
    match try_unwind_dwarf(dump, elf_data) {
        Ok(frames) => DwarfUnwindResult {
            frames,
            cfi_source: Some(CfiSource::EhFrame),
            error: None,
        },
        Err(e) => DwarfUnwindResult {
            frames: vec![dump.pc],
            cfi_source: None,
            error: Some(e),
        },
    }
}

fn try_unwind_dwarf(dump: &CrashDump, elf_data: &[u8]) -> Result<Vec<u32>, DwarfUnwindError> {
    let obj =
        object::File::parse(elf_data).map_err(|e| DwarfUnwindError::ParseError(e.to_string()))?;

    let section = obj
        .section_by_name(".eh_frame")
        .ok_or(DwarfUnwindError::NoEhFrame)?;

    let section_data = section
        .data()
        .map_err(|e| DwarfUnwindError::ParseError(e.to_string()))?;
    let section_addr = section.address();

    let eh_frame: EhFrame<EndianSlice<BigEndian>> = EhFrame::new(section_data, BigEndian);
    let bases = BaseAddresses::default().set_eh_frame(section_addr);

    walk_frames(&eh_frame, &bases, dump)
}

fn read_stack_u32(stack: &[u8], stack_base: u32, addr: u32) -> Option<u32> {
    let offset = addr.checked_sub(stack_base)? as usize;
    let bytes = stack.get(offset..offset + 4)?;
    Some(u32::from_be_bytes(bytes.try_into().unwrap()))
}

fn is_valid_wii_addr(addr: u32) -> bool {
    (0x80000000..=0x817FFFFF).contains(&addr) || (0x90000000..=0x93FFFFFF).contains(&addr)
}

fn walk_frames(
    section: &EhFrame<EndianSlice<'_, BigEndian>>,
    bases: &BaseAddresses,
    dump: &CrashDump,
) -> Result<Vec<u32>, DwarfUnwindError> {
    let mut frames = vec![dump.pc];
    let mut current_pc = dump.pc;
    let mut current_sp = dump.gpr[1];
    let mut current_lr = dump.lr;
    let stack = &dump.stack;
    let stack_base = dump.gpr[1];

    for _ in 0..64 {
        let next = step_eh(
            section, bases, stack, stack_base, current_pc, current_sp, current_lr,
        )?;

        if !is_valid_wii_addr(next.0) || next.0 == 0 {
            break;
        }
        if next.1 <= current_sp {
            break;
        }

        frames.push(next.0);
        current_lr = next.0;
        current_pc = next.0;
        current_sp = next.1;
    }

    Ok(frames)
}

fn step_eh(
    section: &EhFrame<EndianSlice<'_, BigEndian>>,
    bases: &BaseAddresses,
    stack: &[u8],
    stack_base: u32,
    current_pc: u32,
    current_sp: u32,
    current_lr: u32,
) -> Result<(u32, u32), DwarfUnwindError> {
    let mut ctx = UnwindContext::new();
    let mut entries = section.entries(bases);
    while let Ok(Some(entry)) = entries.next() {
        let partial_fde = match entry {
            CieOrFde::Cie(_) => continue,
            CieOrFde::Fde(f) => f,
        };

        let fde = match partial_fde.parse(|s, b, o| s.cie_from_offset(b, o)) {
            Ok(f) => f,
            Err(_) => continue,
        };

        let fde_start = fde.initial_address();
        let fde_end = fde_start + fde.len();
        if (current_pc as u64) < fde_start || (current_pc as u64) >= fde_end {
            continue;
        }

        let mut table = fde
            .rows(section, bases, &mut ctx)
            .map_err(|e| DwarfUnwindError::ParseError(e.to_string()))?;

        let mut best_cfa: Option<u32> = None;
        let mut best_lr: Option<u32> = None;

        while let Ok(Some(row)) = table.next_row() {
            if row.start_address() > current_pc as u64 {
                break;
            }

            let cfa = match row.cfa() {
                gimli::CfaRule::RegisterAndOffset { register, offset } => {
                    let base = if *register == DWARF_REG_R1 {
                        current_sp
                    } else {
                        continue;
                    };
                    (base as i64 + offset) as u32
                }
                _ => continue,
            };

            let ra_reg = fde.cie().return_address_register();
            let lr = match row.register(ra_reg) {
                None | Some(gimli::RegisterRule::Undefined) => Some(current_lr),
                Some(gimli::RegisterRule::SameValue) => Some(current_lr),
                Some(gimli::RegisterRule::Offset(offset)) => {
                    read_stack_u32(stack, stack_base, (cfa as i64 + offset) as u32)
                }
                Some(gimli::RegisterRule::ValOffset(offset)) => Some((cfa as i64 + offset) as u32),
                _ => Some(current_lr),
            };

            if let Some(pc) = lr {
                best_cfa = Some(cfa);
                best_lr = Some(pc);
            }
        }

        if let (Some(cfa), Some(lr)) = (best_cfa, best_lr) {
            return Ok((lr, cfa));
        }
    }

    Err(DwarfUnwindError::NoFdeForPc(current_pc))
}
