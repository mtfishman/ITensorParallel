using MPI: MPI
MPI.Init()
using ITensorMPS
using ITensorParallel
using ITensors
using LinearAlgebra: BLAS
using Random: Random
using Strided: Strided

electronk_path = joinpath(pkgdir(ITensorMPS), "examples", "src")
include(joinpath(electronk_path, "electronk.jl"))
include(joinpath(electronk_path, "hubbard.jl"))

BLAS.set_num_threads(1)
Strided.disable_threads()

"""
Run at the command line with 4 processes:
```julia
mpiexecjl -n 2 julia -t2 02_mpi_run.jl --Nx 8 --Ny 4 --nsweeps 10 --maxdim 1000

mpiexecjl -n 2 julia -t2 02_mpi_run.jl --Nx 8 --Ny 4 --nsweeps 10 --maxdim 1000 --threaded_blocksparse true

mpiexecjl -n 2 julia -t2 02_mpi_run.jl --Nx 8 --Ny 4 --nsweeps 10 --maxdim 1000 --disk true --threaded_blocksparse true
```
"""
function main(;
  Nx::Int,
  Ny::Int,
  U::Float64=4.0,
  t::Float64=1.0,
  nsweeps=10,
  maxdim::Int=3000,
  conserve_ky=true,
  seed=1234,
  threaded_blocksparse=false,
  disk=false,
  random_init=false,
  in_partition_alg="sum_split",
)
  @show Threads.nthreads()

  ITensors.enable_threaded_blocksparse(threaded_blocksparse)
  @show ITensors.using_threaded_blocksparse()

  N = Nx * Ny

  max_maxdim = maxdim
  maxdim = min.([100, 200, 400, 800, 2000, 3000, max_maxdim], max_maxdim)
  cutoff = 1e-6
  noise = [1e-6, 1e-7, 1e-8, 0.0]
  @show nsweeps
  @show maxdim
  @show cutoff
  @show noise

  # Create a lazy representation of the Hamiltonian
  ℋ = hubbard(; Nx, Ny, t, U, ky=true)

  # Create starting state with checkerboard
  # pattern
  state = map(CartesianIndices((Ny, Nx))) do I
    return iseven(I[1]) ⊻ iseven(I[2]) ? "↓" : "↑"
  end
  display(state)
  ###MPI.Init() currently needs to be called before using ITensors
  #MPI.Init()

  sites = siteinds("ElecK", N; conserve_qns=true, conserve_ky, modulus_ky=Ny)
  sites = ITensorParallel.bcast(sites, 0, MPI.COMM_WORLD)

  if random_init
    # Only available in ITensors 0.3.27
    # Helps make results reproducible when comparing
    # sequential vs. threaded.
    itensor_rng = Xoshiro()
    Random.seed!(itensor_rng, seed)
    psi0 = random_mps(itensor_rng, sites, state; linkdims=10)
  else
    psi0 = MPS(sites, state)
  end
  psi0 = ITensorParallel.bcast(psi0, 0, MPI.COMM_WORLD)

  nprocs = MPI.Comm_size(MPI.COMM_WORLD)
  ℋs = partition(ℋ, nprocs; in_partition_alg)
  which_proc = MPI.Comm_rank(MPI.COMM_WORLD) + 1
  mpo_sum_term = MPISumTerm(MPO(ℋs[which_proc], sites), MPI.COMM_WORLD)

  if disk
    # Write-to-disk
    mpo_sum_term = ITensorMPS.disk(mpo_sum_term)
  end

  energy, psi = @time dmrg(mpo_sum_term, psi0; nsweeps, maxdim, cutoff, noise)

  @show Nx, Ny
  @show t, U
  @show flux(psi)
  @show maxlinkdim(psi)
  @show energy
  return energy, psi
end
