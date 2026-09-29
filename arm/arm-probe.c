#include <stdio.h>
#include <sys/utsname.h>

int main(void)
{
    struct utsname system;
    puts("SBHttpsProxy ARM probe");
    printf("sizeof(void*) = %u\n", (unsigned)sizeof(void *));
    printf("build compiler = %s\n", __VERSION__);
#if defined(__ARM_ARCH)
    printf("ARM target = ARMv%d\n", __ARM_ARCH);
#else
    puts("ARM target = unknown");
#endif
#if defined(__ARM_PCS_VFP)
    puts("float ABI = hard");
#else
    puts("float ABI = soft");
#endif
    if (uname(&system) == 0)
        printf("runtime = %s %s %s %s\n", system.sysname, system.release,
            system.machine, system.version);
    return 0;
}
