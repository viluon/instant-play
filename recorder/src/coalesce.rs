use std::collections::{BTreeMap, HashSet};
use std::io::{self, BufRead, Write};

const GAP: u64 = 65536;

#[derive(Debug, PartialEq)]
pub struct Range {
    pub path: String,
    pub offset: u64,
    pub length: u64,
}

fn store_root(path: &str) -> &str {
    let mut n = 0;
    for (i, b) in path.bytes().enumerate() {
        if b == b'/' {
            n += 1;
            if n == 4 {
                return &path[..i];
            }
        }
    }
    path
}

pub fn coalesce<R: BufRead>(
    reader: R,
    allowed: Option<&HashSet<String>>,
) -> io::Result<Vec<Range>> {
    let mut by_path: BTreeMap<String, Vec<(u64, u64)>> = BTreeMap::new();
    for line in reader.lines() {
        let line = line?;
        let mut it = line.rsplitn(3, '\t');
        let (Some(len), Some(off), Some(path)) = (it.next(), it.next(), it.next()) else {
            continue;
        };
        let (Ok(off), Ok(len)) = (off.parse::<u64>(), len.parse::<u64>()) else {
            continue;
        };
        if len == 0 {
            continue;
        }
        if let Some(allowed) = allowed {
            if !allowed.contains(store_root(path)) {
                continue;
            }
        }
        by_path
            .entry(path.to_string())
            .or_default()
            .push((off, len));
    }

    let mut out = Vec::new();
    for (path, mut reads) in by_path {
        reads.sort_unstable();
        let (mut start, mut end) = (reads[0].0, reads[0].0 + reads[0].1);
        for &(o, l) in &reads[1..] {
            let e = o + l;
            if o <= end.saturating_add(GAP) {
                end = end.max(e);
            } else {
                out.push(Range {
                    path: path.clone(),
                    offset: start,
                    length: end - start,
                });
                start = o;
                end = e;
            }
        }
        out.push(Range {
            path: path.clone(),
            offset: start,
            length: end - start,
        });
    }
    Ok(out)
}

pub fn write_json<W: Write>(w: &mut W, ranges: &[Range]) -> io::Result<()> {
    write!(w, "[")?;
    for (i, r) in ranges.iter().enumerate() {
        if i > 0 {
            write!(w, ",")?;
        }
        write!(
            w,
            "{{\"path\":{},\"offset\":{},\"length\":{}}}",
            json_string(&r.path),
            r.offset,
            r.length
        )?;
    }
    writeln!(w, "]")
}

fn json_string(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn run(input: &str) -> Vec<Range> {
        coalesce(Cursor::new(input), None).unwrap()
    }

    #[test]
    fn merges_adjacent_and_gap_within_threshold() {
        let out = run("/a\t0\t100\n/a\t100\t100\n/a\t200000000\t50\n");
        assert_eq!(out.len(), 2);
        assert_eq!(
            out[0],
            Range {
                path: "/a".into(),
                offset: 0,
                length: 200
            }
        );
        assert_eq!(
            out[1],
            Range {
                path: "/a".into(),
                offset: 200000000,
                length: 50
            }
        );
    }

    #[test]
    fn out_of_order_reads_are_sorted() {
        let out = run("/a\t500\t100\n/a\t0\t100\n");
        assert_eq!(out.len(), 1);
        assert_eq!(
            out[0],
            Range {
                path: "/a".into(),
                offset: 0,
                length: 600
            }
        );
    }

    #[test]
    fn separate_paths_and_zero_reads() {
        let out = run("/a\t0\t10\n/b\t0\t0\n/b\t5\t10\ngarbage\n");
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].path, "/a");
        assert_eq!(
            out[1],
            Range {
                path: "/b".into(),
                offset: 5,
                length: 10
            }
        );
    }

    #[test]
    fn json_escapes() {
        let mut buf = Vec::new();
        write_json(
            &mut buf,
            &[Range {
                path: "/a b\"c".into(),
                offset: 1,
                length: 2,
            }],
        )
        .unwrap();
        assert_eq!(
            String::from_utf8(buf).unwrap(),
            "[{\"path\":\"/a b\\\"c\",\"offset\":1,\"length\":2}]\n"
        );
    }

    #[test]
    fn filters_to_allowed_store_roots() {
        let allowed = HashSet::from(["/nix/store/keep-a".to_string()]);
        let out = coalesce(
            Cursor::new("/nix/store/keep-a/x\t0\t10\n/nix/store/drop-b/y\t0\t10\n"),
            Some(&allowed),
        )
        .unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].path, "/nix/store/keep-a/x");
    }
}
