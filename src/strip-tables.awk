# Skip the INSERT statements of tables matching comma-separated patterns (`*` is a wildcard) and keep everything else,
# so those tables are created empty: awk -v patterns="session,report_event,quote*" -f strip-tables.awk
# A statement ends at a physical line ending in `;`: dumpers escape newlines inside values, so both the single-line
# extended INSERT of mysqldump and multi-line INSERTs with one row group per line are handled.

BEGIN {
    n = split(patterns, pats, ",")
    for (i = 1; i <= n; i++) {
        p = pats[i]
        gsub(/[ \t]/, "", p)
        if (p == "") continue
        gsub(/[.\\^$()+{}|\[\]]/, "\\\\&", p)
        gsub(/\*/, ".*", p)
        res[++m] = "^INSERT INTO `" p "`[ (]"
    }
    skip = 0
}

{
    if (skip) {
        if ($0 ~ /;[ \t\r]*$/) skip = 0
        next
    }
    for (i = 1; i <= m; i++) {
        if ($0 ~ res[i]) {
            if ($0 !~ /;[ \t\r]*$/) skip = 1
            next
        }
    }
    print
}
