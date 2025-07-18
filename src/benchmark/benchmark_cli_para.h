#pragma once

#include <cstdlib>
#include <string>
#include "benchmark_case_type.h"
#include "benchmark_object_type.h"

namespace tinyptr {

class BenchmarkCLIPara {
   private:
    static void configuring_getopt();

   public:
    BenchmarkCLIPara() = default;
    ~BenchmarkCLIPara() = default;

    void Parse(int argc, char** argv);
    std::string GetOuputFileName();

   public:
    // FIXME: consider size_t or other more constrained types
    int case_id;
    int entry_id;
    int object_id;

    int thread_num = 0;

    int table_size;
    uint64_t opt_num;

    double load_factor;
    double hit_percent;

    double zipfian_skew = 0.0;

    int quotienting_tail_length;
    int bin_size;

    bool rand_mem_free = false;

    std::string path;
    std::string ycsb_load_path;
    std::string ycsb_run_path;
};
}  // namespace tinyptr