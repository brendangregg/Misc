awk 'BEGIN { OFS = "," } $1 == "OUT:" { print $3, $6 }'
