## READING THE DIFFS

Per-file diffs with 20 lines of surrounding context are at `/tmp/diffs/<filepath>.diff`.
Read each file's diff using: `Read /tmp/diffs/<filepath>.diff`

For each changed file, read the diff first, then read the full source file to understand surrounding context.
If a diff file is empty, the file may have been renamed or had only permission/binary changes — read the full source file directly.
If the diff shows a file was **deleted**, skip reading the source — the file no longer exists at HEAD.
