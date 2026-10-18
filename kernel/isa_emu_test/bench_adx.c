#include <stdint.h>

#define ITERATIONS 50000ULL

struct timespec {
    long tv_sec;
    long tv_nsec;
};

static long sc3(long n, long a, long b, long c)
{
    long r;
    __asm__ volatile("syscall"
        : "=a"(r)
        : "0"(n), "D"(a), "S"(b), "d"(c)
        : "rcx", "r11", "memory");
    return r;
}

static long sc4(long n, long a, long b, long c, long d)
{
    long r;
    register long r10 __asm__("r10") = d;
    __asm__ volatile("syscall"
        : "=a"(r)
        : "0"(n), "D"(a), "S"(b), "d"(c), "r"(r10)
        : "rcx", "r11", "memory");
    return r;
}

static void write_str(const char *s, long n)
{
    sc3(1, 1, (long)s, n);
}

static int append_u64(char *buf, uint64_t value)
{
    char rev[24];
    int n = 0, i;
    do {
        rev[n++] = '0' + value % 10;
        value /= 10;
    } while (value);
    for (i = 0; i < n; i++)
        buf[i] = rev[n - 1 - i];
    return n;
}

__attribute__((used, noinline)) void bench_main(void)
{
    struct timespec start, end;
    uint64_t count = ITERATIONS;
    uint64_t a, d, elapsed;
    char out[160];
    int n = 0;

    if (sc3(228, 1, (long)&start, 0) != 0) {
        write_str("BENCH_ERROR clock_gettime_start\n", 33);
        goto poweroff;
    }

    /*
     * Haswell lacks ADX. ADCX and ADOX should therefore trap into
     * the kernel emulator. LOOP preserves the arithmetic flags.
     * Keep both ADX instructions at fixed instruction addresses.
     */
    {
        register uint64_t z1 __asm__("r8") = 0;
        register uint64_t z2 __asm__("r9") = 0;

        __asm__ volatile(
            "xorq %%rax, %%rax\n\t"
            "xorq %%rdx, %%rdx\n\t"
            "movabsq $0x7fffffffffffffff, %%r10\n\t"
            "addq $1, %%r10\n\t"
            "stc\n\t"
            "1:\n\t"
            "adcxq %[z1], %%rax\n\t"
            "adoxq %[z2], %%rdx\n\t"
            "loop 1b\n\t"
            : "=&a"(a), "=&d"(d), "+c"(count)
            : [z1] "r"(z1), [z2] "r"(z2)
            : "r10", "cc", "memory");
    }

    if (sc3(228, 1, (long)&end, 0) != 0) {
        write_str("BENCH_ERROR clock_gettime_end\n", 31);
        goto poweroff;
    }

    elapsed = (uint64_t)(end.tv_sec - start.tv_sec) * 1000000000ULL;
    if (end.tv_nsec >= start.tv_nsec)
        elapsed += (uint64_t)(end.tv_nsec - start.tv_nsec);
    else
        elapsed -= (uint64_t)(start.tv_nsec - end.tv_nsec);

    n += append_u64(out + n, ITERATIONS);
    __builtin_memcpy(out + n, " iterations; ", 13); n += 13;
    n += append_u64(out + n, ITERATIONS * 2);
    __builtin_memcpy(out + n, " ADX instructions; ", 18); n += 18;
    n += append_u64(out + n, elapsed);
    __builtin_memcpy(out + n, " elapsed_ns\n", 12); n += 12;
    write_str("BENCH ", 6);
    write_str(out, n);

poweroff:
    sc4(169, 0xfee1dead, 0x28121969, 0x4321fedc, 0);
    for (;;)
        __asm__ volatile("pause");
}

__attribute__((naked, noreturn)) void _start(void)
{
    __asm__ volatile(
        "xor %ebp, %ebp\n\t"
        "and $-32, %rsp\n\t"
        "call bench_main\n\t"
        "ud2\n\t");
}
