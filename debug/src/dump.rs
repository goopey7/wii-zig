use anyhow::{Context, Result, bail};
use std::io::Read;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum Exid {
    SystemReset = 1,
    MachineCheck = 2,
    Dsi = 3,
    Isi = 4,
    Interrupt = 5,
    Alignment = 6,
    UNDEF = 7,
    FloatingPoint = 8,
    Decrementer = 9,
    SystemCall = 12,
    Trace = 13,
    PerformanceMonitor = 15,
    BKPT = 19,
    ZigPanic = 20,
    Unknown = 0xFFFFFFFF,
}

impl Exid {
    fn from_u32(v: u32) -> Self {
        match v {
            1 => Self::SystemReset,
            2 => Self::MachineCheck,
            3 => Self::Dsi,
            4 => Self::Isi,
            5 => Self::Interrupt,
            6 => Self::Alignment,
            7 => Self::UNDEF,
            8 => Self::FloatingPoint,
            9 => Self::Decrementer,
            12 => Self::SystemCall,
            13 => Self::Trace,
            15 => Self::PerformanceMonitor,
            19 => Self::BKPT,
            20 => Self::ZigPanic,
            _ => Self::Unknown,
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::SystemReset => "System Reset",
            Self::MachineCheck => "Machine Check",
            Self::Dsi => "DSI (Data Storage)",
            Self::Isi => "ISI (Instruction Storage)",
            Self::Interrupt => "External Interrupt",
            Self::Alignment => "Alignment",
            Self::UNDEF => "UNDEF",
            Self::FloatingPoint => "Floating Point Unavailable",
            Self::Decrementer => "Decrementer",
            Self::SystemCall => "System Call",
            Self::Trace => "Trace",
            Self::PerformanceMonitor => "Performance Monitor",
            Self::BKPT => "IABR",
            Self::ZigPanic => "Zig Panic",
            Self::Unknown => "Unknown",
        }
    }
}

#[derive(Debug)]
pub struct CrashDump {
    pub exid: Exid,
    pub pc: u32,
    pub lr: u32,
    pub ctr: u32,
    pub cr: u32,
    pub xer: u32,
    pub msr: u32,
    pub gpr: [u32; 32],
    pub fpr: [u64; 32],
    pub fpscr: u64,
    pub gqr: [u32; 8],
    pub ps: [u64; 32],
    pub stack_len: u32,
    pub stack: Vec<u8>,
}

fn read_u32(r: &mut impl Read) -> Result<u32> {
    let mut b = [0u8; 4];
    r.read_exact(&mut b)?;
    Ok(u32::from_be_bytes(b))
}

fn read_u64(r: &mut impl Read) -> Result<u64> {
    let mut b = [0u8; 8];
    r.read_exact(&mut b)?;
    Ok(u64::from_be_bytes(b))
}

fn read_u32_array<const N: usize>(r: &mut impl Read) -> Result<[u32; N]> {
    let mut arr = [0u32; N];
    for x in arr.iter_mut() {
        *x = read_u32(r)?;
    }
    Ok(arr)
}

fn read_u64_array<const N: usize>(r: &mut impl Read) -> Result<[u64; N]> {
    let mut arr = [0u64; N];
    for x in arr.iter_mut() {
        *x = read_u64(r)?;
    }
    Ok(arr)
}

impl CrashDump {
    pub fn from_file(path: &str) -> Result<Self> {
        let data =
            std::fs::read(path).with_context(|| format!("Failed to read dump file: {}", path))?;
        Self::parse(&data)
    }

    pub fn parse(data: &[u8]) -> Result<Self> {
        let mut r = data;

        let exid = Exid::from_u32(read_u32(&mut r)?);
        let pc = read_u32(&mut r)?;
        let lr = read_u32(&mut r)?;
        let ctr = read_u32(&mut r)?;
        let cr = read_u32(&mut r)?;
        let xer = read_u32(&mut r)?;
        let msr = read_u32(&mut r)?;
        let gpr = read_u32_array::<32>(&mut r)?;
        let fpr = read_u64_array::<32>(&mut r)?;
        let fpscr = read_u64(&mut r)?;
        let gqr = read_u32_array::<8>(&mut r)?;
        let ps = read_u64_array::<32>(&mut r)?;
        let stack_len = read_u32(&mut r)?;

        if r.len() < stack_len as usize {
            bail!(
                "Truncated dump: expected {} bytes of stack, got {}",
                stack_len,
                r.len()
            );
        }
        let stack = r[..stack_len as usize].to_vec();

        Ok(CrashDump {
            exid,
            pc,
            lr,
            ctr,
            cr,
            xer,
            msr,
            gpr,
            fpr,
            fpscr,
            gqr,
            ps,
            stack_len,
            stack,
        })
    }
}
