! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
! H0 X
! H0 X   libAtoms+QUIP: atomistic simulation library
! H0 X
! H0 X   Portions of this code were written by
! H0 X     Albert Bartok-Partay, Silvia Cereda, Gabor Csanyi, James Kermode,
! H0 X     Ivan Solt, Wojciech Szlachta, Csilla Varnai, Steven Winfield.
! H0 X
! H0 X   Copyright 2006-2010.
! H0 X
! H0 X   These portions of the source code are released under the GNU General
! H0 X   Public License, version 2, http://www.gnu.org/copyleft/gpl.html
! H0 X
! H0 X   If you would like to license the source code under different terms,
! H0 X   please contact Gabor Csanyi, gabor@csanyi.net
! H0 X
! H0 X   Portions of this code were written by Noam Bernstein as part of
! H0 X   his employment for the U.S. Government, and are not subject
! H0 X   to copyright in the USA.
! H0 X
! H0 X
! H0 X   When using this software, please cite the following reference:
! H0 X
! H0 X   http://www.libatoms.org
! H0 X
! H0 X  Additional contributions by
! H0 X    Alessio Comisso, Chiara Gattinoni, and Gianpietro Moras
! H0 X
! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

! IR intensities from K. Jackson, M. R. Pederson, and D. Porezag,
! Z. Hajnal, and T. Frauenheim, Phys. Rev. B v. 55, 2549 (1997).
#include "error.inc"
module phonons_module
use libatoms_module
use mpi_context_module, only : free_context
use potential_module
use libatoms_misc_utils_module
implicit none
private

real(dp), parameter :: PHONON_FORCE_TOLERANCE = 1.0e-12_dp

public :: Phonon_fine
type Phonon_fine
   integer :: n_qvectors, n_modes
   real(dp), dimension(:,:), allocatable :: q, frequency, hessian
   complex(dp), dimension(:,:,:,:), allocatable :: eigenvector
   logical :: initialised = .false.
endtype Phonon_fine

public phonons_all, dynamical_matrix_solve, Phonon_fine_calc_print, eval_frozen_phonon

public :: initialise
interface initialise
   module procedure Phonon_fine_initialise
endinterface initialise

public :: finalise
interface finalise
   module procedure Phonon_fine_finalise
endinterface finalise

public :: calc
interface calc
   module procedure Phonon_fine_calc
endinterface calc

public :: print
interface print
   module procedure Phonon_fine_print
endinterface print

contains

   subroutine Phonon_fine_initialise(this,error)
      type(Phonon_fine), intent(inout) :: this
      integer, intent(out), optional :: error

      INIT_ERROR(error)

      if(this%initialised) call finalise(this,error)

      this%initialised = .true.
   endsubroutine Phonon_fine_initialise

   subroutine Phonon_fine_allocate(this,n_modes,n_qvectors,error)
      type(Phonon_fine), intent(inout) :: this
      integer, intent(in) :: n_modes, n_qvectors
      integer, intent(out), optional :: error

      INIT_ERROR(error)

      if( mod(n_modes,3) /= 0 ) then
         RAISE_ERROR('Phonon_fine_allocate: number of modes must be multiple of 3, n_modes = '//n_modes, error)
      endif

      if(this%initialised) call finalise(this,error)
      this%n_qvectors = n_qvectors
      this%n_modes = n_modes
      allocate(this%q(3,this%n_qvectors))
      allocate(this%frequency(this%n_modes,this%n_qvectors))
      allocate(this%eigenvector(3,n_modes/3,n_modes,n_qvectors))

      this%initialised = .true.

   endsubroutine Phonon_fine_allocate

   subroutine Phonon_fine_finalise(this,error)
      type(Phonon_fine), intent(inout) :: this
      integer, intent(out), optional :: error

      INIT_ERROR(error)

      if(.not. this%initialised) return
      if(allocated(this%q)) deallocate( this%q )
      if(allocated(this%frequency)) deallocate( this%frequency )
      if(allocated(this%eigenvector)) deallocate( this%eigenvector )
      if(allocated(this%hessian)) deallocate( this%hessian )
      this%n_qvectors = 0
      
      this%initialised = .false.

   endsubroutine Phonon_fine_finalise

   subroutine Phonon_fine_print(this,file,error)
      type(Phonon_fine), intent(inout) :: this
      type(Inoutput), intent(inout), target, optional :: file
      integer, intent(out), optional :: error

      type(Inoutput), pointer :: my_file => null()
      integer :: k, t_real_precision

      INIT_ERROR(error)

      if(.not. this%initialised) then
         RAISE_ERROR('Phonon_fine_print: not initialised', error)
      endif

      if(present(file)) then
         my_file => file
      else
         my_file => mainlog
      endif
      
      t_real_precision = my_file%default_real_precision
      call print("PHONON results begin", file=my_file)
      call print("                   q-vector (1/Angstrom)                                     frequency (THz)", file=my_file)
      do k = 1, this%n_qvectors
         my_file%default_real_precision=6
         call print("PHONONS_FINE "//this%q(:,k), nocr=.true.,file=my_file)
         my_file%default_real_precision=9
         call print("    "//this%frequency(:,k)*1000.0_dp,file=my_file)
      enddo
      call print("PHONON results end", file=my_file)
      my_file%default_real_precision = t_real_precision

      my_file => null()

   endsubroutine Phonon_fine_print

   subroutine Phonon_fine_calc(this,pot, at_in, dx, &
         phonon_supercell, phonon_supercell_fine, calc_args, do_parallel, &
         phonons_path_start, phonons_path_end, phonons_path_steps, do_phonopy_force_const_mat, error)

      type(Phonon_fine), intent(inout) :: this

      type(Potential), intent(inout) :: pot
      type(Atoms), intent(inout) :: at_in
      real(dp), intent(in) :: dx
      character(len=*), intent(in), optional :: calc_args
      logical, intent(in), optional :: do_phonopy_force_const_mat
      logical :: my_phonopy_force_const_mat
      logical, intent(in), optional :: do_parallel
      integer, dimension(3), intent(in), optional :: phonon_supercell, phonon_supercell_fine
      real(dp), dimension(3), intent(in), optional :: phonons_path_start, phonons_path_end
      integer, intent(in), optional :: phonons_path_steps
      integer, intent(out), optional :: error
    
      type(Atoms) :: at, at_fine
      integer :: i, j, k, alpha, beta, n, n1, n2, n3, jn, j_fine
      integer, dimension(3) :: do_phonon_supercell, do_phonon_supercell_fine
      integer, dimension(:,:,:,:), allocatable :: map_at_fine
    
      real(dp) :: r_ij, dm(3), at_max_cutoff
      complex(dp) :: exp_I_k_R
      real(dp), dimension(3) :: pp, diff_ij
      integer, dimension(3) :: shift_ij, j_SI, j_SI_fine
      real(dp), dimension(:), allocatable :: evals, at_in_sqrt_mass
      real(dp), dimension(:,:), allocatable :: pos0
      real(dp), dimension(:,:,:,:), allocatable :: fp0, fm0, fp0_fine, fm0_fine
      complex(dp), dimension(:,:), allocatable :: dmft, evecs
      integer, dimension(:,:), pointer :: phonons_SI, phonons_fine_SI
      logical, dimension(:), allocatable :: at_fine_mapped
    
      real(dp), dimension(:,:), allocatable :: frac
      integer :: do_phonons_path_steps

      integer :: primcell_counter,i_n,n1i,n2i,n3i,n1eff,n2eff,n3eff,jneff
      real(dp), dimension(:,:,:,:), allocatable :: fine_force_const
      real(dp), dimension(3,3) :: super_cell_lattice,fract_matrix
      !character(2), dimension(1,len(at_in%species)) :: species_array
      integer :: i_species
    
      INIT_ERROR(error)
    
      call finalise(this, error)

      my_phonopy_force_const_mat = optional_default(.false., do_phonopy_force_const_mat)

      do_phonon_supercell = optional_default((/1,1,1/),phonon_supercell)
      do_phonon_supercell_fine = optional_default(do_phonon_supercell,phonon_supercell_fine)
    
      if( any( do_phonon_supercell_fine < do_phonon_supercell ) ) then
         RAISE_ERROR("phonons_fine: phonon_supercell = ("//phonon_supercell//") greater than phonon_supercell_fine =("//phonon_supercell_fine//")",error)
      endif
    
      call supercell(at,at_in,do_phonon_supercell(1),do_phonon_supercell(2),do_phonon_supercell(3),supercell_index_name="phonons_SI")
    
      if (present(phonons_path_start) .and. present(phonons_path_end)) then
         do_phonons_path_steps = optional_default(3, phonons_path_steps)
         call Phonon_fine_allocate(this,at_in%N*3,do_phonons_path_steps + 2,error)
    
         do i = 1, this%n_qvectors
            this%q(:, i) = 2.0_dp * PI * matmul((phonons_path_start + ((phonons_path_end - phonons_path_start) * (real((i - 1), dp) / real((this%n_qvectors - 1), dp)))), at_in%g)
         enddo
      else
         call Phonon_fine_allocate(this,at_in%N*3,product(do_phonon_supercell_fine),error)
    
         i = 0
         do n1 = 0, do_phonon_supercell_fine(1)-1
            do n2 = 0, do_phonon_supercell_fine(2)-1
               do n3 = 0, do_phonon_supercell_fine(3)-1
                  i = i + 1
    
                  this%q(:,i) = 2*PI*matmul( ( (/real(n1,dp),real(n2,dp),real(n3,dp)/) / do_phonon_supercell_fine ), at_in%g )
               enddo
            enddo
         enddo
      endif
    
      allocate(pos0(3,at%N))
    
      if (dx == 0.0_dp) then
         RAISE_ERROR("phonons called with dx == 0.0",error)
      endif
    
      call set_cutoff(at, cutoff(pot), cutoff_skin=0.5_dp)
    
      pos0 = at%pos
    
      allocate(fp0(3,at%N,3,at_in%N),fm0(3,at%N,3,at_in%N))

      if(allocated(this%hessian)) deallocate(this%hessian)
      allocate(this%hessian(3*at%N,3*at_in%N))

      fp0 = 0.0_dp
      fm0 = 0.0_dp
    
      call system_timer("Phonon_fine_calc/force")
      call print("Starting force calculations")
      do i = 1, at_in%N
         call print('Displacing atom '//i//' of '//at_in%N)
         do alpha = 1, 3
            at%pos = pos0
            at%pos(alpha,i) = at%pos(alpha,i) + dx
            call calc_dists(at)
            call calc(pot, at, force=fp0(:,:,alpha,i), args_str=calc_args)
    
            at%pos = pos0
            at%pos(alpha,i) = at%pos(alpha,i) - dx
            call calc_dists(at)
            call calc(pot, at, force=fm0(:,:,alpha,i), args_str=calc_args)
         enddo
      enddo
      call print("Finished force calculations")
      call system_timer("Phonon_fine_calc/force")
    
      do i = 1, at_in%N
         do alpha = 1, 3
            do j = 1, at%N
               do beta = 1, 3
                  this%hessian((j-1)*3+beta,(i-1)*3+alpha) = - (fp0(beta,j,alpha,i) - fm0(beta,j,alpha,i)) / 2.0_dp / dx
               enddo
            enddo
         enddo
      enddo

      at%pos = pos0
      call calc_dists(at)
      deallocate(pos0)
    
      call supercell(at_fine,at_in,do_phonon_supercell_fine(1),do_phonon_supercell_fine(2),do_phonon_supercell_fine(3),supercell_index_name="phonons_fine_SI")

      if(.not. assign_pointer(at,"phonons_SI",phonons_SI) .or. .not. assign_pointer(at_fine,"phonons_fine_SI",phonons_fine_SI)) then
         RAISE_ERROR("phonons_fine: couldn't assign phonons_SI and phonons_fine_SI pointers",error)
      endif
    
      allocate(fp0_fine(3,at_fine%N,3,at_in%N),fm0_fine(3,at_fine%N,3,at_in%N))
      fp0_fine = 0.0_dp
      fm0_fine = 0.0_dp

      allocate(map_at_fine(0:at_in%N-1,0:do_phonon_supercell_fine(1)-1,0:do_phonon_supercell_fine(2)-1,0:do_phonon_supercell_fine(3)-1))
      do i = 1, at_fine%N
         map_at_fine(mod(i,at_in%N),phonons_fine_SI(1,i),phonons_fine_SI(2,i),phonons_fine_SI(3,i)) = i
      enddo

      if( all(do_phonon_supercell == do_phonon_supercell_fine) ) then
         fp0_fine = fp0
         fm0_fine = fm0
      else
         at_max_cutoff = max_cutoff(at%lattice,error)
         if( at_max_cutoff <= cutoff(pot) ) then
            RAISE_ERROR("phonons_fine: if cutoff sphere cannot fit in supercell, it is not possible to map supercell atoms to supercell_fine atoms",error)
         endif

         do i = 1, at_in%N
            fp0_fine(:,i,:,i) = fp0(:,i,:,i)
            fm0_fine(:,i,:,i) = fm0(:,i,:,i)

            do j = 1, at%N
               r_ij = distance_min_image(at,i,j,shift=shift_ij)
               if( r_ij >= at_max_cutoff ) then
                  if( any(abs(fp0(:,j,:,i)) > PHONON_FORCE_TOLERANCE) .or. any(abs(fm0(:,j,:,i)) > PHONON_FORCE_TOLERANCE) ) then
                     call print_warning( "Phonon_fine_calc: in the supercell there are non-zero forces on atoms outside of the minimum-image cutoff sphere. &
                     Phonons computed in the fine supercell may be inaccurate. This problem may be eliminated by increasing phonon_supercell. &
                     Atoms in supercell: "//i//" and"//j//" from "//r_ij//" A from each other, forces are: "//reshape(fp0(:,j,:,i),(/9/)) &
                     //" "//reshape(fm0(:,j,:,i),(/9/)) )
                  endif
               endif
               shift_ij = phonons_SI(:,j) + shift_ij * do_phonon_supercell

               j_SI_fine = mod(shift_ij + do_phonon_supercell_fine,do_phonon_supercell_fine)
               j_fine = map_at_fine(mod(j,at_in%N),j_SI_fine(1),j_SI_fine(2),j_SI_fine(3))
               fp0_fine(:,j_fine,:,i) = fp0(:,j,:,i)
               fm0_fine(:,j_fine,:,i) = fm0(:,j,:,i)
            enddo
         enddo

      endif
    
      call system_timer("Phonon_fine_calc/phonon")
      call print("Starting phonon calculations")

! Printing out the force constant and atomic positions in the phonopy format:
      if_my_phonopy_force_const_mat: if (my_phonopy_force_const_mat) then
         call print_warning("phonopy_force_const_mat: This program prints out the force constants and atoms in the way phonopy 1.12.4 expects them. It is not guaranteed to work with other versions and does only support a single atomic species at a time (no alloys).")
         !species_array = at_in%species
!         do i_species = 2,len(at_in%species)
!            print *, at_in%species(:,1)
!            if ( (at_in%species(:,1)) /= (at_in%species(:,i_species)) ) then
!                print *, at_in%species(:,i_species)
!                call system_abort("Only one species is supported. Aborting program.")
!            endif
!         enddo
         call print("Force constant matrix using supercell/supercell fine:")

         allocate(fine_force_const(at_in%N,3,do_phonon_supercell_fine(1)*do_phonon_supercell_fine(2)*do_phonon_supercell_fine(3)*at_in%N,3))

         do i = 1, at_in%N
            do alpha = 1, 3
               do beta = 1, 3
                  primcell_counter = 0
                  do n1 = 0, do_phonon_supercell_fine(1)-1
                     do n2 = 0, do_phonon_supercell_fine(2)-1
                        do n3= 0, do_phonon_supercell_fine(3)-1
                           do j = 1, at_in%N
                              primcell_counter = primcell_counter + 1
                              jn = ((n1*do_phonon_supercell_fine(2)+n2)*do_phonon_supercell_fine(3)+n3)*at_in%N+j

                              fine_force_const(i,alpha,jn,beta) = -(fp0_fine(beta,jn,alpha,i)-fm0_fine(beta,jn,alpha,i))/(2.0_dp*dx)
                          enddo ! j
                        enddo ! n3
                     enddo ! n2
                  enddo ! n1
               enddo ! beta
            enddo ! alpha
         enddo ! i

         print *, do_phonon_supercell_fine(1)*do_phonon_supercell_fine(2)*do_phonon_supercell_fine(3)*at_in%N


!Some loops needed to be reveresed compared to the phonon calculation further below as phonopy orders the supercell atoms differently than we do:
         do i = 1, at_in%N
            do n3i = 0, do_phonon_supercell_fine(3)-1
            do n2i = 0, do_phonon_supercell_fine(2)-1
            do n1i = 0, do_phonon_supercell_fine(1)-1
!               i_n = ((n1i*do_phonon_supercell_fine(2)+n2i)*do_phonon_supercell_fine(3)+n3i)*at_in%N+i
               i_n = 1 + (((i-1)*do_phonon_supercell_fine(3)+n3i)*do_phonon_supercell_fine(2)+n2i)*do_phonon_supercell_fine(1)+n1i
               primcell_counter = 0
               do j = 1, at_in%N
                  do n3 = 0, do_phonon_supercell_fine(3)-1
                  do n2 = 0, do_phonon_supercell_fine(2)-1
                  do n1 = 0, do_phonon_supercell_fine(1)-1
                     jn = 1 + (((j-1)*do_phonon_supercell_fine(3)+n3)*do_phonon_supercell_fine(2)+n2)*do_phonon_supercell_fine(1)+n1

                     n1eff = mod(do_phonon_supercell_fine(1) + n1 - n1i,do_phonon_supercell_fine(1))
                     n2eff = mod(do_phonon_supercell_fine(2) + n2 - n2i,do_phonon_supercell_fine(2))
                     n3eff = mod(do_phonon_supercell_fine(3) + n3 - n3i,do_phonon_supercell_fine(3))

                     !This makes sure that we use the right atom (regarding the supercell as well as the phonopy atom numbering convention).
                     jneff = ((n1eff*do_phonon_supercell_fine(2)+n2eff)*do_phonon_supercell_fine(3)+n3eff)*at_in%N+j

                     print *, i_n, jn
                     do alpha = 1, 3

                        print *, fine_force_const(i,1,jneff,alpha), fine_force_const(i,2,jneff,alpha), &
                               & fine_force_const(i,3,jneff,alpha)

                     enddo ! beta

                  enddo ! n1
                  enddo ! n2
                  enddo ! n3
               enddo ! j
            enddo ! n1i
            enddo ! n2i
            enddo ! n3i
         enddo ! i


         deallocate(fine_force_const)

         print *, "Atom postions for above given force constant in format for phonopy:"

         print *, at_in%species(:,1)
         print *, 1.0_dp
         super_cell_lattice(1,:) = at_in%lattice .mult. (/do_phonon_supercell_fine(1),0,0/)
         super_cell_lattice(2,:) = at_in%lattice .mult. (/0,do_phonon_supercell_fine(2),0/)
         super_cell_lattice(3,:) = at_in%lattice .mult. (/0,0,do_phonon_supercell_fine(3)/)
         do i = 1,3
            print *, super_cell_lattice(i,:)
         enddo
         print *, do_phonon_supercell_fine(1)*do_phonon_supercell_fine(2)*do_phonon_supercell_fine(3)*at_in%N
         print *, "Direct"

         fract_matrix = transpose(super_cell_lattice)
         call inverse(fract_matrix)
         

         do j = 1, at_in%N
            do n3= 0, do_phonon_supercell_fine(3)-1
               do n2 = 0, do_phonon_supercell_fine(2)-1
                  do n1 = 0, do_phonon_supercell_fine(1)-1

                     pp = at_in%lattice .mult. (/n1,n2,n3/)

                     print *, (fract_matrix .mult. (at_in%pos(:,j) + pp))
                  enddo ! n1
               enddo ! n2
            enddo ! n3
         enddo ! j

         print *, "Finished atom postions for above given force constant in format for phonopy:"
      endif if_my_phonopy_force_const_mat
! Finished phonopy force constant and atom positions

    
      allocate(at_in_sqrt_mass(at_in%N))
      do i = 1, at_in%N
         at_in_sqrt_mass(i) = sqrt(ElementMass(at_in%Z(i)))
      enddo

      !$omp parallel default(none) private(dmft,evals,evecs) shared(this,at_in,do_phonon_supercell_fine,fp0_fine,fm0_fine,dx,at_in_sqrt_mass,map_at_fine)
      allocate(dmft(at_in%N*3,at_in%N*3))
      allocate(evals(at_in%N*3), evecs(at_in%N*3,at_in%N*3))
      !$omp do private(k,i,j,alpha,diff_ij,n1,n2,n3,pp,jn,dm,exp_I_k_R)
      do k = 1, this%n_qvectors
         call system_timer("Phonon_fine_calc/dynamical_matrix")
         dmft = CPLX_ZERO
         do n1 = 0, do_phonon_supercell_fine(1)-1
            do n2 = 0, do_phonon_supercell_fine(2)-1
               do n3= 0, do_phonon_supercell_fine(3)-1
                  pp = at_in%lattice .mult. (/n1,n2,n3/)

                  do j = 1, at_in%N
                     !jn = ((n1*do_phonon_supercell_fine(2)+n2)*do_phonon_supercell_fine(3)+n3)*at_in%N+j
                     jn = map_at_fine(mod(j,at_in%N),n1,n2,n3)

                     do i = 1, at_in%N
                        diff_ij = at_in%pos(:,j) - at_in%pos(:,i) + pp
                        exp_I_k_R = exp( CPLX_IMAG * dot_product(this%q(:,k),diff_ij) )


                        do alpha = 1, 3
                           dm = - (fp0_fine(:,jn,alpha,i)-fm0_fine(:,jn,alpha,i))/(2.0_dp*dx) / (at_in_sqrt_mass(i) * at_in_sqrt_mass(j))

                           dmft((i-1)*3+alpha,(j-1)*3+1:j*3) = dmft((i-1)*3+alpha,(j-1)*3+1:j*3) + dm * exp_I_k_R
                        enddo ! alpha

                     enddo ! i
                  enddo ! j
               enddo ! n3
            enddo ! n2
         enddo ! n1

         do i = 1, 3*at_in%N
            dmft(i,i) = CPLX_ONE*real(dmft(i,i))
            do j = i+1, 3*at_in%N
               dmft(i,j) = conjg(dmft(j,i))
            enddo
         enddo
         call system_timer("Phonon_fine_calc/dynamical_matrix")

         call system_timer("Phonon_fine_calc/eig")
         call diagonalise(dmft, evals, evecs)
         call system_timer("Phonon_fine_calc/eig")
         this%frequency(:,k) = sign(sqrt(abs(evals)),evals)/2.0_dp/PI
         this%eigenvector(:,:,:,k) = reshape( evecs, (/3, at_in%N, 3*at_in%N /) )

      enddo ! k
      !$omp end do
      deallocate(dmft)
      deallocate(evecs,evals)
      !$omp end parallel  
      call print("Finished phonon calculations")
      call system_timer("Phonon_fine_calc/phonon")
      
      deallocate(fp0, fp0_fine, fm0, fm0_fine, at_in_sqrt_mass)
      deallocate(map_at_fine)
      call finalise(at,at_fine)
   endsubroutine Phonon_fine_calc

   subroutine Phonon_fine_calc_print(pot, at_in, dx, &
         phonon_supercell, phonon_supercell_fine, calc_args, do_parallel, &
         phonons_path_start, phonons_path_end, phonons_path_steps, file, do_phonopy_force_const_mat, error)

      type(Potential), intent(inout) :: pot
      type(Atoms), intent(inout) :: at_in
      real(dp), intent(in) :: dx
      character(len=*), intent(in), optional :: calc_args
      logical, intent(in), optional :: do_phonopy_force_const_mat
      logical, intent(in), optional :: do_parallel
      integer, dimension(3), intent(in), optional :: phonon_supercell, phonon_supercell_fine
      real(dp), dimension(3), intent(in), optional :: phonons_path_start, phonons_path_end
      integer, intent(in), optional :: phonons_path_steps
      type(Inoutput), intent(inout), optional :: file
      integer, intent(out), optional :: error

      type(Phonon_fine) :: my_phonon_fine

      call calc(my_phonon_fine, pot, at_in, dx, &
         phonon_supercell, phonon_supercell_fine, calc_args, do_parallel, &
         phonons_path_start, phonons_path_end, phonons_path_steps, do_phonopy_force_const_mat, error)

      call print(my_phonon_fine,file,error)
      call finalise(my_phonon_fine, error)

   endsubroutine Phonon_fine_calc_print

function eval_frozen_phonon(pot, at, dx, evec, calc_args)
  type(Potential), intent(inout) :: pot
  type(Atoms), intent(inout) :: at
  real(dp), intent(in) :: dx
  real(dp), intent(in) :: evec(:)
  character(len=*), intent(in), optional :: calc_args
  real(dp) :: eval_frozen_phonon ! result

  real(dp) :: Ep, E0, Em
! for potentially more accurate, 4th order fit
!  real(dp) :: Ep2, Em2
  real(dp), allocatable :: pos0(:,:), dpos(:,:)
  real(dp) :: b, d, t1, t2

  allocate(pos0(3,at%N))
  allocate(dpos(3,at%N))

  pos0 = at%pos

  dpos = reshape(evec, (/ 3, at%N /) )
  dpos = dpos / sqrt(sum(dpos**2))

  call calc_dists(at)
  call calc(pot, at, energy=E0, args_str=calc_args)
  mainlog%prefix="FROZ_E0"
  call set_value(at%params, "frozen_phonon_E0", E0)
  call write(at, 'stdout')
  call remove_value(at%params, "frozen_phonon_E0")
  mainlog%prefix=""

  at%pos = pos0 + dx*dpos

  call calc_dists(at)
  call calc(pot, at, energy=Ep, args_str=calc_args)
  call set_value(at%params, "frozen_phonon_Ep", Ep)
  call write(at, 'stdout', prefix='FROZ_EP')
  call remove_value(at%params, "frozen_phonon_Ep")

  at%pos = pos0 - dx*dpos

  call calc_dists(at)
  call calc(pot, at, energy=Em, args_str=calc_args)
  call set_value(at%params, "frozen_phonon_Em", Em)
  call write(at, 'stdout', prefix='FROZ_EM')
  call remove_value(at%params, "frozen_phonon_Em")

  call print("frozen phonon Em " // Em // " E0 " // E0 // " Ep " // Ep, PRINT_VERBOSE)

  eval_frozen_phonon = ((Ep-E0)/dx - (E0-Em)/dx)/dx

! more accurate 4th order fit.
!
!   at%pos = pos0 + 2.0_dp*dx*dpos
! 
!   call calc_dists(at)
!   call calc(pot, at, energy=Ep2, args_str=calc_args)
!   mainlog%prefix="FROZ_EP2"
!   call set_value(at%params, "frozen_phonon_Ep2", Ep2)
!   call print_xyz(at, mainlog, real_format='f14.6', properties="pos:phonon")
!   call remove_value(at%params, "frozen_phonon_Ep2")
!   mainlog%prefix=""
! 
!   at%pos = pos0 - 2.0_dp*dx*dpos
! 
!   call calc_dists(at)
!   call calc(pot, at, energy=Em2, args_str=calc_args)
!   mainlog%prefix="FROZ_EM2"
!   call set_value(at%params, "frozen_phonon_Em2", Em2)
!   call print_xyz(at, mainlog, real_format='f14.6', properties="pos:phonon")
!   call remove_value(at%params, "frozen_phonon_Em2")
!   mainlog%prefix=""
!   t1 = (Ep + Em - 2.0_dp*E0)/(2.0_dp*dx**2)
!   t2 = (Ep2 + Em2 - 2.0_dp*E0)/(8.0_dp*dx**2)
!   d = (t2-t1)/(3.0_dp*dx**2)
!   b = t1 - d*dx**2
!   eval_frozen_phonon = 2.0_dp*b

  at%pos = pos0
  call calc_dists(at)

  deallocate(dpos)
  deallocate(pos0)

end function eval_frozen_phonon

subroutine dynamical_matrix_solve(at, fc_mat, evals, evecs, zero_translation, zero_rotation)
    type(Atoms), intent(inout) :: at
    real(dp), intent(inout) :: fc_mat(:,:)
    real(dp), intent(inout) :: evals(:)
    real(dp), intent(inout), optional :: evecs(:,:)
    logical, intent(in), optional :: zero_translation, zero_rotation

    logical :: do_zero_translation, do_zero_rotation
    integer :: n_zero
    logical :: override_zero_freq_phonons = .true.
    real(dp), allocatable :: phonon(:,:), zero_phonon(:,:), zero_phonon_p(:,:), P(:,:), fc_mat_t(:,:)
    integer :: i, j, beta
    real(dp) :: phonon_norm, CoM(3), axis(3), dr_proj(3)
    integer :: err
    real(dp), allocatable :: zero_overlap_inv(:,:)
    real(dp) :: sym_val

    do_zero_translation = optional_default(.true., zero_translation)
    do_zero_rotation = optional_default(.false., zero_rotation)

  ! transform from generalized eigenproblem to regular eigenproblem
  do i=1, at%N
    do j=1, at%N
fc_mat((i-1)*3+1:(i-1)*3+3,(j-1)*3+1:(j-1)*3+3) = fc_mat((i-1)*3+1:(i-1)*3+3,(j-1)*3+1:(j-1)*3+3) / &
					sqrt(ElementMass(at%Z(i))*ElementMass(at%Z(j)))
    end do
  end do

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  n_zero = 0
  if (do_zero_translation) n_zero = n_zero + 3
  if (do_zero_rotation) n_zero = n_zero + 3

  if (n_zero > 0) then
    allocate(zero_phonon(at%N*3,n_zero))
    allocate(zero_phonon_p(at%N*3,n_zero))
    allocate(phonon(3,at%N))
    do i=1, n_zero
      if (do_zero_translation .and. i <= 3) then ! if zeroing both, then 1st 3 are translation
	beta = i
	phonon = 0.0_dp
	phonon(beta,:) = 1.0_dp
      else ! rotation
	if (i > 3) then ! must have already done zero_rotation
	  beta = i-3
	else
	  beta = i
	end if
	CoM = centre_of_mass(at)
	axis = 0.0_dp; axis(beta) = 1.0_dp
	do j=1, at%N
	  dr_proj = at%pos(:,j)-CoM
	  dr_proj(beta) = 0.0_dp
	  phonon(:,j) = dr_proj .cross. axis
	end do
      endif
      phonon_norm=sqrt(sum(ElementMass(at%Z)*sum(phonon**2,1)))
      zero_phonon(:,i) = reshape(phonon/phonon_norm, (/ 3*at%N /) )
    end do ! i
    deallocate(phonon)

    ! transform from generalized eigenproblem to regular eigenproblem
    do i=1, at%N
      zero_phonon((i-1)*3+1:(i-1)*3+3,:) = zero_phonon((i-1)*3+1:(i-1)*3+3,:)*sqrt(ElementMass(at%Z(i)))
    end do

    allocate(zero_overlap_inv(n_zero,n_zero))
    ! project out zero frequency modes
    do i=1, n_zero
      do j=1, n_zero
	zero_overlap_inv(i,j) = sum(zero_phonon(:,i)*zero_phonon(:,j))
      end do
    end do
    call inverse(zero_overlap_inv)

    zero_phonon_p = 0.0_dp; call matrix_product_sub(zero_phonon_p, zero_phonon, zero_overlap_inv)
    deallocate(zero_overlap_inv)

    allocate(fc_mat_t(at%N*3,at%N*3))
    allocate(P(at%N*3,at%N*3))
    P = 0.0_dp; call matrix_product_sub(P, zero_phonon_p, zero_phonon, .false., .true.)
    deallocate(zero_phonon_p)
    P = -P
    call add_identity(P)

    fc_mat_t = 0.0_dp; call matrix_product_sub(fc_mat_t, fc_mat, P)
    fc_mat = 0.0_dp; call matrix_product_sub(fc_mat, P, fc_mat_t)
    deallocate(fc_mat_t)
    deallocate(P)
  end if

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  ! symmetrize dynamical matrix exactly
  do i=1, 3*at%N
    do j=i+1, 3*at%N
      sym_val = 0.5_dp*(fc_mat(j,i)+fc_mat(i,j))
      fc_mat(i,j) = sym_val
      fc_mat(j,i) = sym_val
    end do
  end do

  call print("fc_mat", PRINT_NERD)
  call print(fc_mat, PRINT_NERD)

  ! diagonalise dynamical matrix
  call diagonalise(fc_mat, evals, evecs, error=err)
  if (err /= 0) then
    call system_abort("calc_phonons got error " // err // " in diagonalise")
  endif

  if (override_zero_freq_phonons .and. do_zero_rotation) then
    zero_phonon(:,n_zero-1) = zero_phonon(:,n_zero-1)-zero_phonon(:,n_zero-2)*sum(zero_phonon(:,n_zero-1)*zero_phonon(:,n_zero-2))
    zero_phonon(:,n_zero-1) = zero_phonon(:,n_zero-1)/sqrt(sum(zero_phonon(:,n_zero-1)**2))
    zero_phonon(:,n_zero) = zero_phonon(:,n_zero)-zero_phonon(:,n_zero-2)*sum(zero_phonon(:,n_zero)*zero_phonon(:,n_zero-2))
    zero_phonon(:,n_zero) = zero_phonon(:,n_zero)-zero_phonon(:,n_zero-1)*sum(zero_phonon(:,n_zero)*zero_phonon(:,n_zero-1))
    zero_phonon(:,n_zero) = zero_phonon(:,n_zero)/sqrt(sum(zero_phonon(:,n_zero)**2))
    evecs(:,1:n_zero) = zero_phonon
  endif
  if (n_zero > 0) deallocate(zero_phonon)

end subroutine dynamical_matrix_solve

subroutine phonons_all(pot, at, dx, evals, evecs, effective_masses, calc_args, IR_intensities, do_parallel, &
		   zero_translation, zero_rotation, force_const_mat)
  type(Potential), intent(inout) :: pot
  type(Atoms), intent(inout) :: at
  real(dp), intent(in) :: dx
  real(dp), intent(out) :: evals(at%N*3)
  real(dp), intent(out), optional :: evecs(at%N*3,at%N*3)
  real(dp), intent(out), optional :: effective_masses(at%N*3)
  character(len=*), intent(in), optional :: calc_args
  real(dp), intent(out), optional :: IR_intensities(:)
  logical, intent(in), optional :: do_parallel
  logical, intent(in), optional :: zero_translation, zero_rotation
  real(dp), intent(out), optional :: force_const_mat(:,:)

  integer i, j, alpha, beta
  integer err
  real(dp), allocatable :: pos0(:,:), f0(:,:), fp(:,:), fm(:,:)
  real(dp) :: E0, Ep, Em
  real(dp), allocatable :: dm(:,:)

  real(dp) :: mu_m(3), mu_p(3), dmu_dq(3)
  real(dp), allocatable :: dmu_dr(:,:,:)
  real(dp), pointer :: local_dn(:), mass(:)

  integer :: n_zero
  logical :: do_zero_translation, do_zero_rotation

  integer :: ind
  logical :: my_do_parallel
  type(MPI_context) :: mpi_glob

  my_do_parallel = optional_default(.false., do_parallel)

  if (my_do_parallel) then
    call initialise(mpi_glob)
  endif

  do_zero_translation = optional_default(.true., zero_translation)
  do_zero_rotation = optional_default(.false., zero_rotation)

  allocate(pos0(3,at%N))
  allocate(f0(3,at%N))
  allocate(fp(3,at%N))
  allocate(fm(3,at%N))
  allocate(dm(at%N*3,at%N*3))
  allocate(dmu_dr(3, at%N, 3))

  if (present(force_const_mat)) then
    if (size(force_const_mat,1) /= size(dm,1) .or. size(force_const_mat,2) /= size(dm,2)) &
      call system_abort("phonons received force_const_mat, shape="//shape(force_const_mat) // &
			" which doesn't match shape(dm)="//shape(dm))
  endif

  if (present(IR_intensities)) then
    if (.not. assign_pointer(at, 'local_dn', local_dn)) then
      call add_property(at, 'local_dn', 0.0_dp, 1)
    endif
  endif

  if (dx == 0.0_dp) &
    call system_abort("phonons called with dx == 0.0")

  if (my_do_parallel) then
    dm = 0.0_dp
    dmu_dr = 0.0_dp
  endif

  call set_cutoff(at, cutoff(pot))
  call calc_connect(at)

  call calc(pot, at, energy=E0, force=f0, args_str=calc_args)
  pos0 = at%pos

  ! calculate dynamical matrix with finite differences
  ind = -1
  do i=1, at%N
    do alpha=1,3
      ind = ind + 1
      if (my_do_parallel) then
	if (mod(ind, mpi_glob%n_procs) /= mpi_glob%my_proc) cycle
      endif

      at%pos = pos0
      at%pos(alpha,i) = at%pos(alpha,i) + dx
      call calc_dists(at)
      call calc(pot, at, energy=Ep, force=fp, args_str=calc_args)
      if (present(IR_intensities)) then
	if (.not. assign_pointer(at, 'local_dn', local_dn)) &
	  call system_abort("phonons impossible failure to assign pointer for local_dn")
	mu_p = dipole_moment(at%pos, local_dn)
      endif

      at%pos = pos0
      at%pos(alpha,i) = at%pos(alpha,i) - dx
      call calc_dists(at)
      call calc(pot, at, energy=Em, force=fm, args_str=calc_args)
      if (present(IR_intensities)) then
	if (.not. assign_pointer(at, 'local_dn', local_dn)) &
	  call system_abort("phonons impossible failure to assign pointer for local_dn")
	mu_m = dipole_moment(at%pos, local_dn)
      endif

      call print("dynamical matrix energy check (Em-E0) " // (Em-E0) // " (Ep-E0) " // (Ep-E0), PRINT_NERD)
      call print("dynamical matrix magnitude check |fp-f0| " // sqrt(sum(normsq(fp-f0,2))) // " |fm-f0| " // sqrt(sum(normsq(fm-f0,2))) // &
	" |fp-f0|-|fm-f0| " // (sqrt(sum(normsq(fp-f0,2)))-sqrt(sum(normsq(fm-f0,2)))), PRINT_NERD)
      call print("dynamical matrix harmonicity check (|fp+fm|/2 - f0)/(0.5*(|fp-f0|+|fm-f0|)) "// &
	(sqrt(sum(normsq(0.5_dp*(fp+fm)-f0,2)))/(0.5_dp*(sqrt(sum(normsq(fp-f0,2)))+sqrt(sum(normsq(fm-f0,2)))))) , PRINT_NERD)

      dmu_dr(alpha, i, :) = (mu_p-mu_m)/(2.0_dp*dx)

      do j=1, at%N
	do beta=1,3
	  dm((i-1)*3+alpha,(j-1)*3+beta) = -((fp(beta,j)-fm(beta,j))/(2.0_dp*dx))
	end do
      end do

    end do
  end do

  at%pos = pos0
  call calc_dists(at)

  if (my_do_parallel) then
    call sum_in_place(mpi_glob, dm)
    call sum_in_place(mpi_glob, dmu_dr)
  endif

  if (.not. assign_pointer(at, 'mass', mass)) &
    call add_property(at, 'mass', 0.0_dp, 1)
  if (.not. assign_pointer(at, 'mass', mass)) &
    call system_abort("impossible failure to assign pointer for mass")
  do i=1, at%N
    mass(i) = ElementMass(at%Z(i))
  end do

  if (present(force_const_mat)) then
    force_const_mat = dm
  endif

  call dynamical_matrix_solve(at, dm, evals, evecs, zero_translation, zero_rotation)

  ! transform from evecs of regular eigenproblem to evecs of original generalized eigenproblem
  if (present(evecs)) then
    do i=1, at%N
      evecs((i-1)*3+1:(i-1)*3+3,:) = evecs((i-1)*3+1:(i-1)*3+3,:) / sqrt(ElementMass(at%Z(i))) 
    end do
  endif

  ! calculate effective masses
  if (present(effective_masses)) then
    do i=1, 3*at%N
      effective_masses(i) = 0.0_dp
      do j=1, at%N
         effective_masses(i) = 1.0_dp/sum(evecs(:,i)**2)
      end do
    end do
  endif

  if (present(IR_intensities)) then
    do i=1, at%N*3
      dmu_dq(1) = sum(dmu_dr(:,:,1)*reshape(evecs(:,i), (/ 3, at%N /) ) )
      dmu_dq(2) = sum(dmu_dr(:,:,2)*reshape(evecs(:,i), (/ 3, at%N /) ) )
      dmu_dq(3) = sum(dmu_dr(:,:,3)*reshape(evecs(:,i), (/ 3, at%N /) ) )
      IR_intensities(i) = 3.0_dp/(PI*3.0*10**3)*sum(dmu_dq**2)
    end do
  endif

  call print("evals", PRINT_VERBOSE)
  call print(evals, PRINT_VERBOSE)
  if (present(evecs)) then
    call print("evecs", PRINT_NERD)
    call print(evecs, PRINT_NERD)
  endif
  if (present(effective_masses)) then
    call print("effective masses", PRINT_VERBOSE)
    call print(effective_masses, PRINT_VERBOSE)
  endif
  if (present(IR_intensities)) then
    call print("IR intensities", PRINT_VERBOSE)
    call print(IR_intensities, PRINT_VERBOSE)
  endif

  deallocate(dmu_dr)
  deallocate(pos0)
  deallocate(fp)
  deallocate(fm)
  deallocate(dm)

end subroutine phonons_all

!subroutine phonons_fine(pot, at_in, dx, phonon_supercell, phonon_supercell_fine, calc_args, do_parallel, phonons_output_file, phonons_path_start, phonons_path_end, phonons_path_steps)
!
!  type(Potential), intent(inout) :: pot
!  type(Atoms), intent(inout) :: at_in
!  real(dp), intent(in) :: dx
!  character(len=*), intent(in), optional :: calc_args
!  logical, intent(in), optional :: do_parallel
!  integer, dimension(3), intent(in), optional :: phonon_supercell, phonon_supercell_fine
!  character(len=*), intent(in), optional :: phonons_output_file
!  real(dp), dimension(3), intent(in), optional :: phonons_path_start, phonons_path_end
!  integer, intent(in), optional :: phonons_path_steps
!
!  type(Atoms) :: at, at_fine
!  integer :: i, j, k, alpha, beta, nk, n1, n2, n3, jn
!  integer, dimension(3) :: do_phonon_supercell, do_phonon_supercell_fine
!
!  real(dp), dimension(3) :: pp, diff_ij
!  real(dp), dimension(:,:), allocatable :: evals
!  real(dp), dimension(:,:), allocatable :: q, pos0
!  real(dp), dimension(:,:,:,:), allocatable :: fp0, fm0, fp0_fine, fm0_fine
!  complex(dp), dimension(:,:), allocatable :: dmft
!  complex(dp), dimension(:,:,:), allocatable :: evecs
!  integer, dimension(:,:), pointer :: phonons_fine_SI, phonons_fine_SI_fine
!
!  type(inoutput) :: phonons_output
!  real(dp), dimension(:,:), allocatable :: frac
!  integer :: do_phonons_path_steps
!  integer :: t_real_precision
!
!
!  do_phonon_supercell = optional_default((/1,1,1/),phonon_supercell)
!  do_phonon_supercell_fine = optional_default(do_phonon_supercell,phonon_supercell_fine)
!
!  if( any( do_phonon_supercell_fine < do_phonon_supercell ) ) &
!     call system_abort("phonons_fine: phonon_supercell = ("//phonon_supercell//") greater than phonon_supercell_fine =("//phonon_supercell_fine//")")
!
!  call supercell(at,at_in,do_phonon_supercell(1),do_phonon_supercell(2),do_phonon_supercell(3),supercell_index_name="phonons_fine_SI")
!
!  if (present(phonons_path_start) .and. present(phonons_path_end)) then
!     do_phonons_path_steps = optional_default(3, phonons_path_steps)
!     nk = do_phonons_path_steps + 2
!     allocate(q(3, nk))
!
!     do i = 1, nk
!        q(:, i) = 2.0_dp * PI * matmul((phonons_path_start + ((phonons_path_end - phonons_path_start) * (real((i - 1), dp) / real((nk - 1), dp)))), at_in%g)
!     enddo
!  else
!     nk = product(do_phonon_supercell_fine)
!     allocate(q(3,nk))
!
!     i = 0
!     do n1 = 0, do_phonon_supercell_fine(1)-1
!        do n2 = 0, do_phonon_supercell_fine(2)-1
!           do n3 = 0, do_phonon_supercell_fine(3)-1
!              i = i + 1
!
!              q(:,i) = 2*PI*matmul( ( (/real(n1,dp),real(n2,dp),real(n3,dp)/) / do_phonon_supercell_fine ), at_in%g )
!           enddo
!        enddo
!     enddo
!  endif
!
!  allocate(evals(at_in%N*3,nk), evecs(at_in%N*3,at_in%N*3,nk)) !, dm(at%N*3,at%N*3))
!  allocate(pos0(3,at%N))
!
!  if (dx == 0.0_dp) &
!    call system_abort("phonons called with dx == 0.0")
!
!  call set_cutoff(at, cutoff(pot)+0.5_dp)
!  call calc_connect(at)
!
!  pos0 = at%pos
!
!  ! calculate dynamical matrix with finite differences
!!  do i=1, at%N
!!    do alpha=1,3
!!
!!      at%pos = pos0
!!      at%pos(alpha,i) = at%pos(alpha,i) + dx
!!      call calc_dists(at)
!!      call calc(pot, at, force=fp, args_str=calc_args)
!!
!!      at%pos = pos0
!!      at%pos(alpha,i) = at%pos(alpha,i) - dx
!!      call calc_dists(at)
!!      call calc(pot, at, force=fm, args_str=calc_args)
!!
!!      do j=1, at%N
!!	do beta=1,3
!!	  dm((i-1)*3+alpha,(j-1)*3+beta) = -((fp(beta,j)-fm(beta,j))/(2.0_dp*dx))
!!	end do
!!      end do
!!
!!    end do
!!  end do
!
!  ! that works for perfect diamond cells only
!  allocate(fp0(3,at%N,3,at_in%N),fm0(3,at%N,3,at_in%N))
!
!  do i = 1, at_in%N
!     call print('Displacing atom '//i//' of '//at_in%N)
!     do alpha = 1, 3
!        at%pos = pos0
!        at%pos(alpha,i) = at%pos(alpha,i) + dx
!        call calc_dists(at)
!        call calc(pot, at, force=fp0(:,:,alpha,i), args_str=calc_args)
!
!        at%pos = pos0
!        at%pos(alpha,i) = at%pos(alpha,i) - dx
!        call calc_dists(at)
!        call calc(pot, at, force=fm0(:,:,alpha,i), args_str=calc_args)
!     enddo
!  enddo
!
!  at%pos = pos0
!  call calc_dists(at)
!
!!  do i = 1, at_in%N  ! move atom i
!!
!!     do ni1 = 0, do_phonon_supercell(1)-1
!!        do ni2 = 0, do_phonon_supercell(2)-1
!!           do ni3= 0, do_phonon_supercell(3)-1
!!              ni = ((ni1*do_phonon_supercell(2)+ni2)*do_phonon_supercell(3)+ni3)*at_in%N+i
!!           
!!              do alpha = 1, 3
!!                 do j = 1, at_in%N  ! force on atom j
!!                    do nj1 = 0, do_phonon_supercell(1)-1
!!                       do nj2 = 0, do_phonon_supercell(2)-1
!!                          do nj3= 0, do_phonon_supercell(3)-1
!!                             shift = (/nj1,nj2,nj3/) - (/ni1,ni2,ni3/) + do_phonon_supercell
!!                             shift(1) = mod(shift(1),do_phonon_supercell(1))
!!                             shift(2) = mod(shift(2),do_phonon_supercell(2))
!!                             shift(3) = mod(shift(3),do_phonon_supercell(3))
!!                             nj = ((nj1*do_phonon_supercell(2)+nj2)*do_phonon_supercell(3)+nj3)*at_in%N+j
!!                             nj_orig = ((shift(1)*do_phonon_supercell(2)+shift(2))*do_phonon_supercell(3)+shift(3))*at_in%N+j
!!	                     do beta = 1, 3
!!                                dm((ni-1)*3+alpha,(nj-1)*3+beta) = &
!!                                & -((fp0(beta,nj_orig,alpha,i)-fm0(beta,nj_orig,alpha,i))/(2.0_dp*dx))
!!                             enddo
!!                          enddo
!!                       enddo
!!                    enddo
!!                 enddo
!!              enddo
!!           enddo
!!        enddo
!!     enddo
!!  enddo
!              
!!  deallocate(fp0,fm0)
!
!  at%pos = pos0
!  call calc_dists(at)
!  deallocate(pos0)
!
!  call supercell(at_fine,at_in,do_phonon_supercell_fine(1),do_phonon_supercell_fine(2),do_phonon_supercell_fine(3),supercell_index_name="phonons_fine_SI_fine")
!  if(.not. assign_pointer(at,"phonons_fine_SI",phonons_fine_SI) .or. .not. assign_pointer(at_fine,"phonons_fine_SI_fine",phonons_fine_SI_fine)) &
!     call system_abort("phonons_fine: couldn't assign phonons_fine_SI and phonons_fine_SI_fine pointers")
!
!  allocate(fp0_fine(3,at_fine%N,3,at_in%N),fm0_fine(3,at_fine%N,3,at_in%N))
!  fp0_fine = 0.0_dp
!  fm0_fine = 0.0_dp
!
!  do i = 1, at%N
!     do j = 1, at_fine%N
!        !print*,phonons_fine_SI(:,i)
!        !print*,phonons_fine_SI_fine(:,i)
!        if( all( &
!           ( phonons_fine_SI(:,i) - nint( real(phonons_fine_SI(:,i),dp) / real(do_phonon_supercell,dp) ) * do_phonon_supercell ) &
!           == &
!           ( phonons_fine_SI_fine(:,j) - nint( real(phonons_fine_SI_fine(:,j),dp) / real(do_phonon_supercell_fine,dp) ) * do_phonon_supercell_fine ) &
!           ) .and. mod(i,at_in%N) == mod(j,at_in%N) ) then
!           fp0_fine(:,j,:,:) = fp0(:,i,:,:)
!           fm0_fine(:,j,:,:) = fm0(:,i,:,:)
!        endif
!     enddo
!  enddo
!
!  ! transform from generalized eigenproblem to regular eigenproblem
!!  do i = 1, at%N
!!    do j = 1, at%N
!!      dm((i-1)*3+1:(i-1)*3+3,(j-1)*3+1:(j-1)*3+3) = dm((i-1)*3+1:(i-1)*3+3,(j-1)*3+1:(j-1)*3+3) / &
!!					sqrt(ElementMass(at%Z(i))*ElementMass(at%Z(j)))
!!    enddo
!!  enddo
!
!  ! symmetrize dynamical matrix exactly
!!  do i = 1, 3*at%N
!!    do j = i+1, 3*at%N
!!      dm(i,j) = dm(j,i)
!!    enddo
!!  enddo
!
!!$omp parallel private(dmft)
!  allocate(dmft(at_in%N*3,at_in%N*3))
!!$omp do private(k,i,j,alpha,beta,diff_ij,n1,n2,n3,pp,jn)
!  do k = 1, nk
!     dmft = CPLX_ZERO
!     do i = 1, at_in%N
!        do alpha = 1, 3
!           do j = 1, at_in%N
!              diff_ij = at_in%pos(:,j) - at_in%pos(:,i) 
!              do beta = 1, 3
!  
!                 do n1 = 0, do_phonon_supercell_fine(1)-1
!                    do n2 = 0, do_phonon_supercell_fine(2)-1
!                       do n3= 0, do_phonon_supercell_fine(3)-1
!
!                          pp = at_in%lattice .mult. (/n1,n2,n3/)
!                          jn = ((n1*do_phonon_supercell_fine(2)+n2)*do_phonon_supercell_fine(3)+n3)*at_in%N+j
!
!                          dmft((i-1)*3+alpha,(j-1)*3+beta) = dmft((i-1)*3+alpha,(j-1)*3+beta) &
!                          & - ((fp0_fine(beta,jn,alpha,i)-fm0_fine(beta,jn,alpha,i))/(2.0_dp*dx)) / &
!                          & sqrt(ElementMass(at_in%Z(i))*ElementMass(at_in%Z(j))) &
!                          & * exp( CPLX_IMAG * dot_product(q(:,k),(diff_ij+pp)) )
!
!                       enddo
!                    enddo
!                 enddo
!              enddo
!           enddo
!        enddo
!     enddo
!     do i = 1, 3*at_in%N
!       dmft(i,i) = CPLX_ONE*real(dmft(i,i))
!       do j = i+1, 3*at_in%N
!         dmft(i,j) = conjg(dmft(j,i))
!       enddo
!     enddo
!     call diagonalise(dmft, evals(:,k), evecs(:,:,k))
!  enddo
!!$omp end do
!deallocate(dmft)
!!$omp end parallel  
!  
!  t_real_precision = mainlog%default_real_precision
!  do k = 1, nk
!!     call print('q: '//q(:,k)*a/(2*PI))
!     !call print(evecs(:,:,k))
!     mainlog%default_real_precision=6
!     call print("PHONONS_FINE "//q(:,k), nocr=.true.)
!     mainlog%default_real_precision=9
!     call print("    "//sign(sqrt(abs(evals(:,k))),evals(:,k))/2.0_dp/PI*1000.0_dp)
!     ! print '("PHONONS_FINE ",3F12.6,"  ",'//at_in%N*3//'f15.9)',q(:,k),sign(sqrt(abs(evals(:,k))),evals(:,k))/2.0_dp/PI*1000.0_dp
!  enddo
!  mainlog%default_real_precision = t_real_precision
!
!!  if (present(phonons_output_file)) then
!!     call initialise(phonons_output, phonons_output_file, action=OUTPUT)
!!
!!     call print(" BEGIN header", file=phonons_output)
!!     call print(" Number of ions         " // at_in%N, file=phonons_output)
!!     call print(" Number of branches     " // (at_in%N*3), file=phonons_output)
!!     call print(" Number of wavevectors  " // nk, file=phonons_output)
!!     call print(" Frequencies in         fs-1", file=phonons_output)
!!     call print(" Unit cell vectors (A)", file=phonons_output)
!!     do i = 1, 3
!!        call print("    " // at_in%lattice(1, i) // "    " // at_in%lattice(2, i) // "    " // at_in%lattice(3, i), file=phonons_output)
!!     enddo
!!     call print(" Fractional Co-ordinates", file=phonons_output)
!!     allocate(frac(3, at_in%N))
!!     frac = at_in%g .mult. at_in%pos
!!     do i = 1, at_in%N
!!        call print("     " // i // "     " // frac(1, i) // "    " // frac(2, i) // "    " // frac(3, i) &
!!                   & // "   " // ElementName(at_in%Z(i)) // "        " // ElementMass(at_in%Z(i)), file=phonons_output)
!!     enddo
!!     deallocate(frac)
!!     call print(" END header", file=phonons_output)
!!
!!     do i = 1, nk
!!        call print("     q-pt=    " // i // "   " // q(1, i) // " " // q(2, i) // " " // q(3, i) // "      " // (1.0_dp / real(nk, dp)), file=phonons_output)
!!        do j = 1, (at_in%N*3)
!!           call print("       " // j // "    " // (sign(sqrt(abs(evals(j,i))),evals(j,i))/2.0_dp/PI*1000.0_dp), file=phonons_output)
!!        enddo
!!        call print("                        Phonon Eigenvectors", file=phonons_output)
!!        call print("Mode Ion                X                                   Y                                   Z", file=phonons_output)
!!        do j = 1, (at_in%N*3)
!!           do k = 1, at_in%N
!!              call print("   " // j // "   " // k // " " // evecs(j, (3 * (k - 1)) + 1, i) &
!!                                            & // "     " // evecs(j, (3 * (k - 1)) + 2, i) &
!!                                            & // "     " // evecs(j, (3 * (k - 1)) + 3, i), file=phonons_output)
!!           enddo
!!        enddo
!!     enddo
!!
!!     call finalise(phonons_output)
!!  endif
!
!  deallocate(q, evals, evecs)
!  call finalise(at)
!
!endsubroutine phonons_fine
endmodule phonons_module
