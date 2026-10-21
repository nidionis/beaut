/* beaut — server-oriented command (orchestrator / watch / peers / ...).
   main is separated from the library (src/orch.c) so the C code builds as a
   library + a standalone command. */
#include "orch.h"

int main(int argc, char **argv) {
    return orch_run(argc, argv);
}
