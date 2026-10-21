/* beaut-router — standalone router (front door -> orchestrator).
   main is separated from the library (src/router.c). */
#include "router.h"

int main(int argc, char **argv) {
    return router_run(argc, argv);
}
