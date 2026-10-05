1. Separation of concerns — one function both decides and does the work. Name the two jobs and the line where they are stuck together. A function that only does one of those jobs is none. Example of a hit: a function that chooses which rows to update and then writes them.

2. Reuse — new code reimplements a function that already exists elsewhere in the repo. The fix is to call that function. Before none, Grep outside the diff for it and name the path and symbol. If you cannot name an existing function, this line is none. Two copies that were both added in this diff are not Reuse. Put those on Duplication.

3. Duplication — the same logic is written out twice, and the fix is to keep one copy as the source of truth. The other copy may be in this diff or already in the repo. Before none, search outside the diff. Name both locations and which copy should survive. Do not repeat a Reuse finding here. Reuse means "call the existing function." Duplication means "two peer copies."

4. Readable functions — a changed function is hard to follow because it is over about 40 lines, nested further than a reader can hold, or its name needs "and". Cite the line range. A short function with one clear name is none.
