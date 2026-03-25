use crate::dump::CrashDump;

fn read_u32_be(stack: &[u8], base: u32, addr: u32) -> Option<u32> {
    let offset = addr.checked_sub(base)? as usize;
    let bytes = stack.get(offset..offset + 4)?;
    Some(u32::from_be_bytes(bytes.try_into().unwrap()))
}

pub fn unwind(dump: &CrashDump) -> Vec<u32> {
    let mut frames = vec![dump.pc];

    let mut current_sp = dump.gpr[1];
    let max_frames = 64;

    // only add what's in LR if it's not saved to the stack as well (leaf functions)
    let first_prev_sp = read_u32_be(&dump.stack, current_sp, current_sp);
    let first_frame_saved_lr =
        first_prev_sp.and_then(|prev| read_u32_be(&dump.stack, current_sp, prev + 4));

    if dump.lr != dump.pc && Some(dump.lr) != first_frame_saved_lr {
        frames.push(dump.lr);
    }

    for _ in 0..max_frames {
        let prev_sp = match read_u32_be(&dump.stack, dump.gpr[1], current_sp) {
            Some(v) if v > current_sp => v,
            _ => break,
        };
        if let Some(saved_lr) = read_u32_be(&dump.stack, dump.gpr[1], current_sp + 4) {
            if (0x80000000..=0x817FFFFF).contains(&saved_lr)
                || (0x90000000..=0x93FFFFFF).contains(&saved_lr)
            {
                frames.push(saved_lr);
            }
        }
        current_sp = prev_sp;
    }

    frames
}
