/*
 * R-compatible shim for init_julia
 *
 * R's .C() passes pointers to arguments (int*, char**), but
 * PackageCompiler's init_julia(int, char**) expects int by value.
 * This shim bridges the calling convention.
 *
 * Build: gcc -shared -fPIC -o r_osj_shim.so r_osj_shim.c -L dist/libosj/lib -losj
 */

/* Forward declaration from libosj */
extern void init_julia(int argc, char *argv[]);

/* R-callable wrapper (.C convention: all args are pointers) */
void r_init_julia(int *dummy) {
    char *argv[] = {"libosj", (char*)0};
    init_julia(1, argv);
}
