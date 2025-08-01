import os
import re
import csv


def extract_throughput(file_path):
    """Extract Throughput and Latency from a result file."""
    with open(file_path, 'r') as f:
        content = f.read()

        throughput_match = re.search(
            r'Throughput: (\d+) ops/s', content)
        latency_match = re.search(
            r'Latency: (\d+) ns/op', content)

        throughput = int(throughput_match.group(
            1)) if throughput_match else None
        latency = int(latency_match.group(1)
                      ) if latency_match else None

        return throughput, latency


def extract_memory_usage(file_path):
    """Extract max real and virtual memory usage from a memory usage file."""
    max_real = 0.0
    max_virtual = 0.0

    with open(file_path, 'r') as f:
        for line in f:
            match = re.match(r'\s*\d+\.\d+\s+\d+\.\d+\s+([\d.]+)\s+([\d.]+)', line)
            if match:
                real = float(match.group(1))
                virtual = float(match.group(2))
                max_real = max(max_real, real)
                max_virtual = max(max_virtual, virtual)

    return max_real, max_virtual


def main():
    # Base directory for results
    base_dir = "/home/xt253/TinyPtr/results"
    output_dir = os.path.join(base_dir, "csv")

    print(f"Processing results from {base_dir}")
    print(f"Output will be saved to {output_dir}")

    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)

    # List to store all data entries
    all_data = []

    # Define valid IDs based on the updated bash script
    valid_case_ids = [1]
    valid_object_ids = [4, 6, 7, 12, 15, 19]
    load_factors = [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95]

    # Process only the valid result files
    for case_id in valid_case_ids:
        for object_id in valid_object_ids:
            entry_id = 100  # Starting entry_id
            for load_factor in load_factors:
                filename = f"object_{object_id}_case_{case_id}_entry_{entry_id}_.txt"
                memuse_filename = f"object_{object_id}_case_{case_id}_entry_{entry_id}_memuse.txt"
                file_path = os.path.join(base_dir, filename)
                memuse_file_path = os.path.join(base_dir, memuse_filename)

                if os.path.exists(file_path) and os.path.exists(memuse_file_path):
                    # Read throughput and latency data
                    throughput, latency = extract_throughput(file_path)

                    # Read memory usage data
                    max_real, max_virtual = extract_memory_usage(memuse_file_path)

                    # Skip if we couldn't extract the data
                    if throughput is None or latency is None:
                        print(
                            f"Warning: Could not extract throughput data from {filename}")
                        continue

                    # Store the data with load_factor, max_real, and max_virtual
                    all_data.append(
                        (case_id, object_id, load_factor, throughput, latency, max_real, max_virtual))

                entry_id += 1  # Increment entry_id for each load_factor

    # Write a single CSV file
    csv_filename = "throughput_space_eff_results.csv"
    csv_path = os.path.join(output_dir, csv_filename)

    with open(csv_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        # Write header
        writer.writerow(['case_id', 'object_id', 'load_factor', 'throughput (ops/s)', 'latency (ns/op)', 'max_real (MB)', 'max_virtual (MB)'])
        # Write data
        for entry in all_data:
            writer.writerow(entry)

    print(f"Created {csv_path}")


if __name__ == "__main__":
    main()
