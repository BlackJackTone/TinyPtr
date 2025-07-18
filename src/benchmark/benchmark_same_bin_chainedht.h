#pragma once

#include <cmath>
#include <cstdint>
#include "../same_bin_chained_ht.h"
#include "benchmark_bytearray_chainedht.h"
#include "benchmark_object_64.h"
#include "benchmark_object_type.h"

namespace tinyptr {

class BenchmarkSameBinChained : public BenchmarkChained {
   public:
    static const BenchmarkObjectType TYPE;

   public:
    BenchmarkSameBinChained(int n, uint16_t bin_size);

    ~BenchmarkSameBinChained() = default;

    uint8_t Insert(uint64_t key, uint64_t value);
    uint64_t Query(uint64_t key, uint8_t ptr);
    void Update(uint64_t key, uint8_t ptr, uint64_t value);
    void Erase(uint64_t key, uint8_t ptr);

    double AvgChainLength();
    uint32_t MaxChainLength();
    uint64_t* ChainLengthHistogram();
    void FillChainLength(uint8_t chain_length);
    void set_chain_length(uint64_t chain_length);
    bool QueryNoMem(uint64_t key, uint64_t* value_ptr);

   private:
    SameBinChainedHT* tab;
};

}  // namespace tinyptr