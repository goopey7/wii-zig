use addr2line::Loader;
use anyhow::Result;

pub struct ResolvedFrame {
    pub addr: u64,
    pub function: Option<String>,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub inlined: Vec<String>,
    pub source_context: Vec<SourceLine>,
}

pub struct SourceLine {
    pub line_num: u32,
    pub text: String,
    pub is_crash_line: bool,
}

impl SymbolResolver {}

impl ResolvedFrame {
    fn unknown(addr: u64) -> Self {
        Self {
            addr,
            function: None,
            file: None,
            line: None,
            inlined: vec![],
            source_context: vec![],
        }
    }
}

pub struct SymbolResolver {
    loader: Loader,
}

impl SymbolResolver {
    pub fn load(elf_path: &str) -> Result<Self> {
        let loader = Loader::new(elf_path).map_err(|e| anyhow::anyhow!("{}", e))?;
        Ok(Self { loader })
    }

    pub fn resolve(&self, addr: u64) -> ResolvedFrame {
        let mut frames = match self.loader.find_frames(addr) {
            Ok(f) => f,
            Err(_) => return ResolvedFrame::unknown(addr),
        };

        let mut result = ResolvedFrame::unknown(addr);
        let mut first = true;

        loop {
            match frames.next() {
                Ok(Some(frame)) => {
                    if first {
                        result.function = frame
                            .function
                            .and_then(|f| f.demangle().ok().map(|s| s.into_owned()));
                        result.file = frame
                            .location
                            .as_ref()
                            .and_then(|l| l.file)
                            .map(String::from);
                        result.line = frame.location.as_ref().and_then(|l| l.line);
                        if let (Some(file), Some(line)) = (&result.file, result.line) {
                            result.source_context =
                                self.get_source_context(file, line, 1).unwrap_or_default();
                        }
                        first = false;
                    } else {
                        if let Some(func) = frame.function {
                            if let Ok(name) = func.demangle() {
                                result.inlined.push(name.into_owned());
                            }
                        }
                    }
                }
                _ => break,
            }
        }
        result
    }

    fn get_source_context(&self, path: &str, line: u32, context: usize) -> Option<Vec<SourceLine>> {
        let file = std::fs::read_to_string(path).ok()?;
        let lines: Vec<&str> = file.lines().collect();

        if line == 0 || line as usize > lines.len() {
            return None;
        }

        let line_idx = (line - 1) as usize;
        let start = if line_idx > context {
            line_idx - context
        } else {
            0
        };
        let end = (line_idx + context + 1).min(lines.len());

        let mut result = Vec::new();
        for line_num in start..end {
            let text = lines[line_num].to_string();
            result.push(SourceLine {
                line_num: (line_num + 1) as u32,
                text,
                is_crash_line: line_num == line_idx,
            });
        }

        Some(result)
    }
}
