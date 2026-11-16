# status.awk - align the TSV emitted by share/jq/status-table.jq.
NF == 7 { printf "%-6s %-7s %-5s %-4s %-5s %-13s %-13s\n", $1, $2, $3, $4, $5, $6, $7; next }
{ print }
