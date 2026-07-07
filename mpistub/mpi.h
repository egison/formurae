#pragma once
/* Minimal single-rank MPI stub so Formura-generated code can run
 * without an MPI installation.  Self-messages are matched FIFO
 * (MPI order guarantee for identical (src,dst,comm,tag)). */
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

typedef int MPI_Comm;
typedef int MPI_Datatype;
typedef int MPI_Status;
typedef struct { int done; } MPI_Request;

#define MPI_COMM_WORLD 0
#define MPI_BYTE 1
#define MPI_STATUS_IGNORE ((MPI_Status *)0)

#define MPI_STUB_MAXPEND 4096

static struct { void *data; int count; int tag; int active; long seq; }
  mpi_stub_sends[MPI_STUB_MAXPEND];
static long mpi_stub_seq = 0;

static int MPI_Init(int *argc, char ***argv) { (void)argc; (void)argv; return 0; }
static int MPI_Finalize(void) { return 0; }
static int MPI_Comm_rank(MPI_Comm c, int *r) { (void)c; *r = 0; return 0; }
static int MPI_Comm_size(MPI_Comm c, int *s) { (void)c; *s = 1; return 0; }

static int MPI_Isend(void *buf, int count, MPI_Datatype dt, int dst, int tag,
                     MPI_Comm c, MPI_Request *req) {
  (void)dt; (void)dst; (void)c;
  for (int idx = 0; idx < MPI_STUB_MAXPEND; idx++) {
    if (!mpi_stub_sends[idx].active) {
      mpi_stub_sends[idx].data = malloc((size_t)count);
      memcpy(mpi_stub_sends[idx].data, buf, (size_t)count);
      mpi_stub_sends[idx].count = count;
      mpi_stub_sends[idx].tag = tag;
      mpi_stub_sends[idx].active = 1;
      mpi_stub_sends[idx].seq = mpi_stub_seq++;
      req->done = 1;
      return 0;
    }
  }
  fprintf(stderr, "mpi stub: send table full\n");
  abort();
}

static int MPI_Irecv(void *buf, int count, MPI_Datatype dt, int src, int tag,
                     MPI_Comm c, MPI_Request *req) {
  (void)dt; (void)src; (void)c;
  /* match the OLDEST pending send with this tag (FIFO) */
  int best = -1;
  for (int idx = 0; idx < MPI_STUB_MAXPEND; idx++) {
    if (mpi_stub_sends[idx].active && mpi_stub_sends[idx].tag == tag) {
      if (best < 0 || mpi_stub_sends[idx].seq < mpi_stub_sends[best].seq)
        best = idx;
    }
  }
  if (best < 0) {
    fprintf(stderr, "mpi stub: Irecv posted with no pending send (tag %d)\n", tag);
    abort();
  }
  if (mpi_stub_sends[best].count != count) {
    fprintf(stderr, "mpi stub: size mismatch %d vs %d\n",
            mpi_stub_sends[best].count, count);
    abort();
  }
  memcpy(buf, mpi_stub_sends[best].data, (size_t)count);
  free(mpi_stub_sends[best].data);
  mpi_stub_sends[best].active = 0;
  req->done = 1;
  return 0;
}


typedef int MPI_Op;
#define MPI_MAX 1
#define MPI_MIN 2
#define MPI_SUM 3
#define MPI_DOUBLE 11
#define MPI_IN_PLACE ((void *)1)

static int MPI_Allreduce(const void *sendbuf, void *recvbuf, int count,
                         MPI_Datatype dt, MPI_Op op, MPI_Comm comm) {
  (void)dt; (void)op; (void)comm;
  if (sendbuf != MPI_IN_PLACE) memcpy(recvbuf, sendbuf, (size_t)count * sizeof(double));
  return 0;
}

static int MPI_Wait(MPI_Request *req, MPI_Status *st) {
  (void)req; (void)st;
  return 0;
}
