use addr2line::Loader;
use anyhow::Result;

pub struct ResolvedFrame {
    pub addr: u64,
    pub function: Option<String>,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub inlined: Vec<String>,
}

impl ResolvedFrame {
    fn unknown(addr: u64) -> Self {
        Self {
            addr,
            function: None,
            file: None,
            line: None,
            inlined: vec![],
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
}
