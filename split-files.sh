#!/bin/bash

# Split file by n chunks (byte-based)
# Usage: ./split-files.sh <filename> <number_of_chunks>

if [ $# -ne 2 ]; then
    echo "Usage: $0 <filename> <number_of_chunks>"
    exit 1
fi

filename="$1"
chunks="$2"

if [ ! -f "$filename" ]; then
    echo "Error: File '$filename' not found"
    exit 1
fi

if ! [[ "$chunks" =~ ^[0-9]+$ ]] || [ "$chunks" -le 1 ]; then
    echo "Error: Number of chunks must be a positive integer"
    exit 1
fi

# Get total bytes in file
total_bytes=$(stat -c%s "$filename")
bytes_per_chunk=$((total_bytes / chunks + (total_bytes % chunks > 0 ? 1 : 0)))

echo "Splitting '$filename' ($total_bytes bytes) into $chunks chunks..."

# Split the file by bytes
split -b "$bytes_per_chunk" "$filename" "${filename}_chunk_"

echo "Split complete. Created chunks:"
ls -1 "${filename}_chunk_"*
