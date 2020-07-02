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

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X
!X cp2k_driver_module
!X
!% guts of cp2k driver from template
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

#include "error.inc"

module cp2k_driver_module

use libatoms_module

implicit none

private

public :: do_cp2k_calc
public :: read_output, qmmm_qm_abc, calc_charge_lsd, cp2k_state_change

contains

  subroutine do_cp2k_calc(at, f, e, args_str, error)
    type(Atoms), intent(inout) :: at
    real(dp), intent(out) :: f(:,:), e
    character(len=*), intent(in) :: args_str
    integer, intent(out), optional :: error

    type(Dictionary) :: cli
    character(len=STRING_LENGTH) :: run_type, cp2k_template_file, psf_print, cp2k_program, link_template_file, &
         topology_suffix, qmmm_link_type, qmmm_link_qm_kind
    logical :: clean_up_files, save_output_files, save_output_wfn_files, use_buffer, persistent
    integer :: clean_up_keep_n, persistent_restart_interval, qmmm_link_qm_kind_z
    integer :: max_n_tries
    real(dp) :: max_force_warning
    real(dp) :: qm_vacuum
    real(dp) :: centre_pos(3), cp2k_box_centre_pos(3)
    logical :: auto_centre, has_centre_pos
    logical :: try_reuse_wfn
    character(len=STRING_LENGTH) :: calc_qm_charges, calc_virial
    logical :: do_calc_virial

    character(len=128) :: method

    integer :: link_template_n_lines
    character(len=STRING_LENGTH), allocatable :: link_template_a(:)
    integer :: i_line

    character(len=STRING_LENGTH) :: run_dir

    type(Table) :: qm_list, old_qm_list
    type(Table) :: cut_bonds, old_cut_bonds
    integer, pointer :: cut_bonds_p(:,:), old_cut_bonds_p(:,:)
    integer, allocatable :: qm_list_a(:), old_qm_list_a(:)
    integer, allocatable :: link_list_a(:), old_link_list_a(:), inner_link_list_a(:)
    integer, allocatable :: qm_and_link_list_a(:)
    integer :: i_inner, i_outer, shift(3)
    integer :: counter

    integer :: charge, old_charge
    logical :: do_lsd, old_do_lsd

    logical :: can_reuse_wfn, qm_list_changed, qmmm_link_list_changed, &
         qmmm_same_lattice, qmmm_use_mm_charges, qmmm_link_fix_pbc
    character(len=STRING_LENGTH) :: run_suffix

    logical :: use_QM, use_MM, use_QMMM
    logical :: cp2k_calc_fake

    integer, pointer :: isolated_atom(:)
    integer i, at_Z, insert_pos
    real(dp) :: cur_qmmm_qm_abc(3), old_qmmm_qm_abc(3)

    integer, pointer :: old_cluster_mark_p(:), cluster_mark_p(:)
    logical :: dummy, have_silica_potential, have_titania_potential, silica_add_23_body
    logical :: silica_pos_dep_charges
    real(dp) :: silica_charge_transfer, silicon_charge, oxygen_charge, hydrogen_charge
    integer :: res_num_silica
    logical :: do_mom_cons
    type(Table) :: intrares_impropers

    integer, pointer :: sort_index_p(:), mol_id_p(:)
    integer, allocatable :: rev_sort_index(:)
    type(Inoutput) :: rev_sort_index_io, persistent_run_i_io, persistent_cell_file_io, persistent_traj_io
    character(len=1024) :: l

    integer :: run_dir_i, force_run_dir_i, delete_dir_i

    logical :: at_periodic
    integer :: form_bond(2), break_bond(2)
    real(dp) :: disp(3)

    character(len=STRING_LENGTH) :: verbosity
    character(len=STRING_LENGTH) :: tmp_MM_param_filename, tmp_QM_pot_filename, tmp_QM_basis_filename
    character(len=STRING_LENGTH) :: MM_param_filename, QM_pot_filename, QM_basis_filename
    logical :: truncate_parent_dir
    character(len=STRING_LENGTH) :: dir, tmp_run_dir
    character(len=1024) :: log_sys_command_str
    integer :: tmp_run_dir_i, stat
    logical :: exists, persistent_already_started, persistent_start_cp2k, persistent_frc_exists, create_residue_labels, &
         remove_Si_H_silica_bonds, remove_Ti_H_titania_bonds
    integer :: persistent_run_i, persistent_frc_size, qm_mol_id, n_hydrogen, old_n_hydrogen, n_extra_electrons, old_n_extra_electrons
    integer :: qmmm_link_n_electrons

    type(inoutput) :: cp2k_input_io, cp2k_input_tmp_io
    real(dp) :: wait_time, persistent_max_wait_time

    character(len=100) proj

    INTERFACE     
	elemental function ffsize(f)
	  character(len=*), intent(in)::f
	  integer::ffsize
	end function ffsize
    END INTERFACE


    INIT_ERROR(error)

    call system_timer('do_cp2k_calc')

    call system_timer('do_cp2k_calc/init')
    call initialise(cli)
      call param_register(cli, 'Run_Type', PARAM_MANDATORY, run_type, help_string="Type of run QS, MM, or QMMM")
      call param_register(cli, 'use_buffer', 'T', use_buffer, help_string="If true, use buffer as specified in relevant hybrid_mark")
      call param_register(cli, 'run_suffix', '', run_suffix, help_string="String to append to various marks and saved info to indicate distinct sets of calculations or QM/MM QM regions")
      call param_register(cli, 'cp2k_template_file', 'cp2k_input.template', cp2k_template_file, help_string="filename for cp2k input template")
      call param_register(cli, "qmmm_link_template_file", "", link_template_file, help_string="filename for cp2k link atoms template file")
      call param_register(cli, 'PSF_print', 'NO_PSF', psf_print, help_string="when to print PSF file: NO_PSF, DRIVER_PRINT_AND_SAVE, USE_EXISTING_PSF")
      call param_register(cli, "topology_suffix", "", topology_suffix, help_string="String to append to file containing topology info (for runs that do multiple topologies not to accidentally reuse PSF file")
      call param_register(cli, 'cp2k_program', PARAM_MANDATORY, cp2k_program, help_string="path to cp2k executable")
      call param_register(cli, 'persistent', 'F', persistent, help_string="if true, use persistent connection to cp2k with REFTRAJ")
      call param_register(cli, 'persistent_restart_interval', '100', persistent_restart_interval, help_string="how often to restart cp2k for persistent connection")
      call param_register(cli, 'persistent_max_wait_time', '600.0', persistent_max_wait_time, help_string="Max amount of time in s to wait for forces to be available in persistent mode")
      call param_register(cli, 'clean_up_files', 'T', clean_up_files, help_string="if true, clean up run directory files")
      call param_register(cli, 'clean_up_keep_n', '1', clean_up_keep_n, help_string="number of old run directories to keep if cleaning up")
      call param_register(cli, 'save_output_files', 'T', save_output_files, help_string="if true, save the output files")
      call param_register(cli, 'save_output_wfn_files', 'F', save_output_wfn_files, help_string="if true, save output wavefunction files")
      call param_register(cli, 'max_n_tries', '2', max_n_tries, help_string="max number of times to run cp2k on failure")
      call param_register(cli, 'max_force_warning', '2.0', max_force_warning, help_string="generate warning if any force is larger than this")
      call param_register(cli, 'qm_vacuum', '6.0', qm_vacuum, help_string="amount of vacuum to add to size of qm region in hybrid (and nonperiodic?) runs")
      call param_register(cli, 'try_reuse_wfn', 'T', try_reuse_wfn, help_string="if true, try to reuse previous wavefunction file")
      call param_register(cli, 'have_silica_potential', 'F', have_silica_potential, help_string="if true, use 2.8A SILICA_CUTOFF for the connectivities")
      call param_register(cli, 'have_titania_potential', 'F', have_titania_potential, help_string="if true, use 2.8A TITANIA_CUTOFF for the connectivities")
      call param_register(cli, 'res_num_silica', '1', res_num_silica, help_string="residue number for silica residue")
      call param_register(cli, 'do_mom_cons', 'T', do_mom_cons, help_string="do we need momentum conservation?")
      call param_register(cli, 'auto_centre', 'F', auto_centre, help_string="if true, automatically center configuration.  May cause energy/force fluctuations.  Mutually exclusive with centre_pos")
      call param_register(cli, 'centre_pos', '0.0 0.0 0.0', centre_pos, has_value_target=has_centre_pos, help_string="position to center around, mutually exclusive with auto_centre")
      call param_register(cli, 'cp2k_calc_fake', 'F', cp2k_calc_fake, help_string="if true, do fake cp2k runs that just read from old output files")
      call param_register(cli, 'form_bond', '0 0', form_bond, help_string="extra bond to form (for EVB)")
      call param_register(cli, 'break_bond', '0 0', break_bond, help_string="bond to break (for EVB)")
      call param_register(cli, 'qm_charges', '', calc_qm_charges, help_string="if not blank, name of property to put QM charges in")
      call param_register(cli, 'virial', '', calc_virial, help_string="if not blank, name of property to put virial in")
      call param_register(cli, 'force_run_dir_i', '-1', force_run_dir_i, help_string="if > 0, force to run in this # run directory")
      call param_register(cli, 'tmp_run_dir_i', '-1', tmp_run_dir_i, help_string="if >0, the cp2k run directory will be /tmp/cp2k_run_$tmp_run_dir_i$, and all input files are also copied here when first called")
      call param_register(cli, 'MM_param_file', '', MM_param_filename, help_string="If tmp_run_dir>0, where to find MM parameter file to copy it to the cp2k run dir on /tmp.") !charmm.pot
      call param_register(cli, 'QM_potential_file', '', QM_pot_filename, help_string="If tmp_run_dir>0, where to find QM POTENTIAL file to copy it to the cp2k run dir on /tmp.") !POTENTIAL
      call param_register(cli, 'QM_basis_file', '', QM_basis_filename, help_string="If tmp_run_dir>0, where to find QM BASIS_SET file to copy it to the cp2k run dir on /tmp.") !BASIS_SET
      call param_register(cli, 'silica_add_23_body', 'T', silica_add_23_body, help_string="If true and if have_silica_potential is true, add bonds for silica 2- and 3-body terms to PSF")
      call param_register(cli, 'silica_pos_dep_charges', 'T', silica_pos_dep_charges, help_string="If true and if have_silica_potential is true, use variable charges for silicon and oxygen ions in silica residue")
      call param_register(cli, 'silica_charge_transfer', '2.4', silica_charge_transfer, help_string="Amount of charge transferred from Si to O in silica bulk, per formula unit")
      call param_register(cli, 'remove_Si_H_silica_bonds', 'T', remove_Si_H_silica_bonds, help_string="If true (default) remove any Si-H bonds detected in silica residue")
      call param_register(cli, 'remove_Ti_H_titania_bonds', 'T', remove_Ti_H_titania_bonds, help_string="If true (default) remove any Ti-H bonds detected in titania residue")
      call param_register(cli, 'create_residue_labels', 'T', create_residue_labels, help_string="If true, recreate residue labels each time PSF file is generated (default T)")
      call param_register(cli, 'qmmm_link_type', 'IMOMM', qmmm_link_type, help_string="Type of QMMM links to create: one of IMOMM, PSEUDO or QM_KIND. Default IMOMM")
      call param_register(cli, 'qmmm_link_qm_kind', 'OSTAR', qmmm_link_qm_kind, help_string="QM kind to use for inner boundary atoms when qmmm_link_type=QM_KIND")
      call param_register(cli, 'qmmm_link_qm_kind_z', '8', qmmm_link_qm_kind_z, help_string="Atomic number of QM_KIND species (default 8)")
      call param_register(cli, 'qmmm_link_n_electrons', '1', qmmm_link_n_electrons, help_string="Number of electrons to add per QM-MM link when qmmm_link_type=QM_KIND")
      call param_register(cli, 'qmmm_same_lattice', 'F', qmmm_same_lattice, help_string="If true, use full original MM lattice for QM calculation")
      call param_register(cli, 'qmmm_use_mm_charges', 'T', qmmm_use_mm_charges, help_string="If true (default) use classical point charges of atoms in QM region to calculate total DFT charge")
      call param_register(cli, 'qmmm_link_fix_pbc', 'T', qmmm_link_fix_pbc, help_string="If true (default) move outer atoms in any QM links which straddle a periodic boundary so link is continous")
      call param_register(cli, 'verbosity', 'NORMAL', verbosity, help_string="verbosity level")

      ! should really be ignore_unknown=false, but higher level things pass unneeded arguments down here
      if (.not.param_read_line(cli, args_str, ignore_unknown=.true.,task='cp2k_driver_template args_str')) then
	RAISE_ERROR('cp2k_driver could not parse argument line', error)
      endif
    call finalise(cli)
    do_calc_virial = len_trim(calc_virial) > 0

    call verbosity_push(verbosity_of_str(trim(verbosity)))

    mainlog%prefix="CP2K_DRIVER"

    call print('do_cp2k_calc args_str '//trim(args_str), PRINT_ALWAYS)

    if (.not. is_initialised(at)) then
      RAISE_ERROR("do_cp2k_calc got uninitialized atoms structure", error)
    endif

    if (cp2k_calc_fake) then
      call print("do_fake cp2k calc calculation")
      call do_cp2k_calc_fake(at, f, e, do_calc_virial, args_str)
      return
    endif

    if (have_silica_potential) then
       ! compute silicon_charge and oxygen_charge from silica_charge_transfer such that SiO2 is neutral
       silicon_charge = silica_charge_transfer
       oxygen_charge = -silicon_charge/2.0_dp
       ! compute hydrogen_charge from silicon_charge and oxygen_charge such that Si(OH)_4 is neutral
       hydrogen_charge = -(silicon_charge + 4.0_dp*oxygen_charge)/4.0_dp
    end if

    if (trim(qmmm_link_type) /= 'IMOMM' .and. &
        trim(qmmm_link_type) /= 'PSEUDO' .and. &
        trim(qmmm_link_type) /= 'QM_KIND') then
       RAISE_ERROR("Unknown value for qmmm_link_type "//trim(qmmm_link_type)//" - should be one of IMOMM, PSEUDO, QM_KIND", error)
    end if
    ! Link fixing across periodic boundaries only applies to IMOMM
    qmmm_link_fix_pbc = qmmm_link_fix_pbc .and. trim(qmmm_link_type) == 'IMOMM'

    call print("do_cp2k_calc command line arguments")
    call print("  Run_Type " // Run_Type)
    call print("  use_buffer " // use_buffer)
    call print("  run_suffix " // run_suffix)
    call print("  cp2k_template_file " // cp2k_template_file)
    call print("  qmmm_link_template_file " // link_template_file)
    call print("  PSF_print " // PSF_print)
    call print("  topology_suffix " // trim(topology_suffix))
    call print("  cp2k_program " // trim(cp2k_program))
    call print("  persistent " // persistent)
    if (persistent) call print("  persistent_restart_interval " // persistent_restart_interval)
    if (persistent) call print("  persistent_max_wait_time " // persistent_max_wait_time)
    call print("  clean_up_files " // clean_up_files)
    call print("  clean_up_keep_n " // clean_up_keep_n)
    call print("  save_output_files " // save_output_files)
    call print("  save_output_wfn_files " // save_output_wfn_files)
    call print("  max_n_tries " // max_n_tries)
    call print("  max_force_warning " // max_force_warning)
    call print("  qm_vacuum " // qm_vacuum)
    call print("  try_reuse_wfn " // try_reuse_wfn)
    call print('  have_titania_potential '//have_titania_potential)
    call print('  have_silica_potential '//have_silica_potential)
    if(have_silica_potential) then
       call print('  res_num_silica '//res_num_silica)
       call print('  silica_add_23_body '//silica_add_23_body)
       call print('  silica_pos_dep_charges '//silica_pos_dep_charges)
       call print('  silica_charge_transfer '//silica_charge_transfer)
       call print('  silicon_charge '//silicon_charge)
       call print('  oxygen_charge '//oxygen_charge)
       call print('  hydrogen_charge '//hydrogen_charge)
       call print('  remove_Si_H_silica_bonds '//remove_Si_H_silica_bonds)
       call print('  remove_Ti_H_titania_bonds '//remove_Ti_H_titania_bonds)
    end if
    call print('  auto_centre '//auto_centre)
    call print('  centre_pos '//centre_pos)
    call print('  cp2k_calc_fake '//cp2k_calc_fake)
    call print('  form_bond '//form_bond)
    call print('  break_bond '//break_bond)
    call print('  qm_charges '//trim(calc_qm_charges))
    call print('  virial '//do_calc_virial)
    call print('  force_run_dir_i '//force_run_dir_i)
    call print('  tmp_run_dir_i '//tmp_run_dir_i)
    call print('  MM_param_file '//trim(MM_param_filename))
    call print('  QM_potential_file '//trim(QM_pot_filename))
    call print('  QM_basis_file '//trim(QM_basis_filename))
    call print('  create_residue_labels '//create_residue_labels)
    call print('  qmmm_link_type '//trim(qmmm_link_type))
    call print('  qmmm_link_qm_kind '//trim(qmmm_link_qm_kind))
    call print('  qmmm_link_n_electrons '//qmmm_link_n_electrons)
    call print('  qmmm_same_lattice '//qmmm_same_lattice)
    call print('  qmmm_use_mm_charges '//qmmm_use_mm_charges)
    call print('  qmmm_link_fix_pbc '//qmmm_link_fix_pbc)
    call print('  do_mom_cons '//do_mom_cons)
    call print('  verbosity '//trim(verbosity))

    if (auto_centre .and. has_centre_pos) then
      RAISE_ERROR("do_cp2k_calc got both auto_centre and centre_pos, don't know which centre (automatic or specified) to shift to origin", error)
    endif

    if (tmp_run_dir_i>0 .and. clean_up_keep_n > 0) then
      RAISE_ERROR("do_cp2k_calc got both tmp_run_dir_i(only write on /tmp) and clean_up_keep_n (save in home).",error)
    endif
    call system_timer('do_cp2k_calc/init')

    proj='quip'

    persistent_already_started=.false.

    call system_timer('do_cp2k_calc/run_dir')
    !create run directory now, because it is needed if running on /tmp
    if (tmp_run_dir_i>0) then
      if (persistent) then
	 RAISE_ERROR("Can't do persistent and temp_run_dir_i > 0", error)
      endif
      tmp_run_dir = "/tmp/cp2k_run_"//tmp_run_dir_i
      run_dir = link_run_directory(trim(tmp_run_dir), basename="cp2k_run", run_dir_i=run_dir_i)
      !and copy necessary files for access on /tmp if not yet present
      if (len_trim(MM_param_filename)>0) then
         tmp_MM_param_filename = trim(MM_param_filename)
         truncate_parent_dir=.true.
         do while(truncate_parent_dir)
            if (tmp_MM_param_filename(1:3)=="../") then
               tmp_MM_param_filename=trim(tmp_MM_param_filename(4:))
            else
               truncate_parent_dir=.false.
            endif
         enddo
         if (len_trim(tmp_MM_param_filename)==0) then
	    RAISE_ERROR("Empty tmp_MM_param_filename string",error)
	 endif
         call print("if [ ! -s "//trim(tmp_run_dir)//"/"//trim(tmp_MM_param_filename)//" ] ; then echo 'copy charmm.pot' ; cp "//trim(MM_param_filename)//" "//trim(tmp_run_dir)//"/ ; else echo 'reuse charmm.pot' ; fi")
         call system_command("if [ ! -s "//trim(tmp_run_dir)//"/"//trim(tmp_MM_param_filename)//" ] ; then echo 'copy charmm.pot' ; cp "//trim(MM_param_filename)//" "//trim(tmp_run_dir)//"/ ; fi",status=stat)
         if ( stat /= 0 ) then
	    RAISE_ERROR("Something went wrong when tried to copy "//trim(MM_param_filename)//" into the tmp dir "//trim(tmp_run_dir), error)
	 endif
      endif
      if (len_trim(QM_pot_filename)>0) then
         tmp_QM_pot_filename = trim(QM_pot_filename)
         truncate_parent_dir=.true.
         do while(truncate_parent_dir)
            if (tmp_QM_pot_filename(1:3)=="../") then
               tmp_QM_pot_filename=trim(tmp_QM_pot_filename(4:))
            else
               truncate_parent_dir=.false.
            endif
         enddo
         call print("if [ ! -s "//trim(tmp_run_dir)//"/"//trim(QM_pot_filename)//" ] ; then cp "//trim(QM_pot_filename)//" "//trim(tmp_run_dir)//"/ ; fi")
         call system_command("if [ ! -s "//trim(tmp_run_dir)//"/"//trim(tmp_QM_pot_filename)//" ] ; then echo 'copy QM potential' ; cp "//trim(QM_pot_filename)//" "//trim(tmp_run_dir)//"/ ; fi")
         if ( stat /= 0 ) then
	    RAISE_ERROR("Something went wrong when tried to copy "//trim(QM_pot_filename)//" into the tmp dir "//trim(tmp_run_dir),error)
	 endif
      endif
      if (len_trim(QM_basis_filename)>0) then
         tmp_QM_basis_filename = trim(QM_basis_filename)
         truncate_parent_dir=.true.
         do while(truncate_parent_dir)
            if (tmp_QM_basis_filename(1:3)=="../") then
               tmp_QM_basis_filename=trim(tmp_QM_basis_filename(4:))
            else
               truncate_parent_dir=.false.
            endif
         enddo
         call print("if [ ! -s "//trim(tmp_run_dir)//"/"//trim(QM_basis_filename)//" ] ; then cp "//trim(QM_basis_filename)//" "//trim(tmp_run_dir)//"/ ; fi")
         call system_command("if [ ! -s "//trim(tmp_run_dir)//"/"//trim(tmp_QM_basis_filename)//" ] ; then echo 'copy QM basis' ; cp "//trim(QM_basis_filename)//" "//trim(tmp_run_dir)//"/ ; fi")
         if ( stat /= 0 ) then
	    RAISE_ERROR("Something went wrong when tried to copy "//trim(QM_basis_filename)//" into the tmp dir "//trim(tmp_run_dir),error)
	 endif
      endif
    else ! not tmp
      if (persistent) then
	 if (.not. persistent_already_started) then
	    call system_command("mkdir -p cp2k_run_0")
	 endif
	 force_run_dir_i=0
      endif
      run_dir = make_run_directory("cp2k_run", force_run_dir_i, run_dir_i)
    endif ! tmp_run_dir
    call system_timer('do_cp2k_calc/run_dir')

    if (persistent) then
       call system_timer('do_cp2k_calc/get_persistent_i')
       inquire(file="persistent_run_i", exist=persistent_already_started)

       if (.not. persistent_already_started) then
	 persistent_run_i=1
	 persistent_start_cp2k=.true.
       else
	 persistent_start_cp2k=.false.
	 call initialise(persistent_run_i_io, "persistent_run_i", INPUT)
	 l = read_line(persistent_run_i_io)
	 call finalise(persistent_run_i_io)
	 read (unit=l, fmt=*, iostat=stat) persistent_run_i
	 if (stat /= 0) then
	    RAISE_ERROR("Failed to read persistent_run_i from 'persistent_run_i' file", error)
	 endif
	 persistent_run_i = persistent_run_i + 1

	 if (persistent_run_i > persistent_restart_interval) then
	    ! reset counters
	    persistent_run_i=1
	    persistent_start_cp2k=.true.
	    ! tell running process to stop
	    call initialise(persistent_traj_io, trim(run_dir)//'/quip.persistent.traj.xyz',OUTPUT,append=.false.)
	    call print ("0", file=persistent_traj_io)
	    call finalise(persistent_traj_io)
	    call initialise(persistent_cell_file_io, trim(run_dir)//'/REFTRAJ_READY', OUTPUT, append=.false.)
	    call print("go",file=persistent_cell_file_io)
	    call finalise(persistent_cell_file_io)
	    ! wait
	    call fusleep(5000000)
	    ! clean up files
	    call system_command('cd '//trim(run_dir)//'; rm -f '//&
	       'quip.persistent.traj.* '// &
	       trim(proj)//'-frc-1_[0-9]*.xyz '// &
	       trim(proj)//'-pos-1_[0-9]*.xyz '// &
	       trim(proj)//'-qmcharges--1_[0-9]*.mulliken '// &
	       trim(proj)//'-stress-1_[0-9]*.stress_tensor '// &
	       'REFTRAJ_READY')
	 endif
       endif

       call initialise(persistent_run_i_io, "persistent_run_i", OUTPUT)
       call print(""//persistent_run_i, file=persistent_run_i_io, verbosity=PRINT_ALWAYS)
       call finalise(persistent_run_i_io)
       call system_timer('do_cp2k_calc/get_persistent_i')
    else
      persistent_run_i = 0
    endif

    call system_timer('do_cp2k_calc/copy_templ')
    if (.not. persistent_already_started) then
       ! read template file
       if (tmp_run_dir_i>0) then
	  call print("if [ ! -s "//trim(tmp_run_dir)//"/"//trim(cp2k_template_file)//" ] ; then cp "//trim(cp2k_template_file)//" "//trim(tmp_run_dir)//"/ ; fi")
	  call system_command("if [ ! -s "//trim(tmp_run_dir)//"/"//trim(cp2k_template_file)//" ] ; then cp "//trim(cp2k_template_file)//" "//trim(tmp_run_dir)//"/ ; fi")
	  if ( stat /= 0 ) then
	    RAISE_ERROR("Something went wrong when tried to copy "//trim(cp2k_template_file)//" into the tmp dir "//trim(tmp_run_dir), error)
	  endif
	  call system("cp "//trim(cp2k_template_file)//" "//trim(tmp_run_dir)//"/cp2k_input.inp")
       else
	  call system("cp "//trim(cp2k_template_file)//" "//trim(run_dir)//"/cp2k_input.inp")
       endif

    endif
    call system_timer('do_cp2k_calc/copy_templ')

    if ( (trim(psf_print) /= 'NO_PSF') .and. &
	 (trim(psf_print) /= 'DRIVER_PRINT_AND_SAVE') .and. &
	 (trim(psf_print) /= 'USE_EXISTING_PSF')) then
      RAISE_ERROR("Unknown value for psf_print '"//trim(psf_print)//"'", error)
    endif

    ! parse run_type
    use_QM = .false.
    use_MM = .false.
    use_QMMM = .false.
    select case(trim(run_type))
      case("QS")
	use_QM=.true.
	method="QS"
      case("MM")
	use_MM=.true.
	method="Fist"
      case("QMMM")
	use_QM = .true.
	use_MM = .true.
	use_QMMM = .true.
	method="QMMM"
      case default
	RAISE_ERROR("Unknown run_type "//trim(run_type),error)
    end select

    call system_timer('do_cp2k_calc/calc_connect')
    ! prepare CHARMM params if necessary
    if (use_MM) then
      if (have_silica_potential) then
         call set_cutoff(at,SILICA_2body_CUTOFF)
         call calc_connect(at)         
      elseif (have_titania_potential) then
         call set_cutoff(at,TITANIA_2body_CUTOFF)
         call calc_connect(at)
      else
         ! use hysteretic connect to get nearest neighbour cutoff
         call calc_connect_hysteretic(at, DEFAULT_NNEIGHTOL, DEFAULT_NNEIGHTOL)
      endif
      call map_into_cell(at)
      call calc_dists(at)
    endif
    call system_timer('do_cp2k_calc/calc_connect')

    call system_timer('do_cp2k_calc/make_psf')
    ! if writing PSF file, calculate residue labels, before sort
    if (run_type /= "QS") then
      if (trim(psf_print) == "DRIVER_PRINT_AND_SAVE" .and. create_residue_labels) then
	if (persistent_already_started) then
	  RAISE_ERROR("Trying to rewrite PSF file with persistent_already_started.  Can't change connectivity during persistent cp2k run", error)
	endif
	call create_residue_labels_arb_pos(at,do_CHARMM=.true.,intrares_impropers=intrares_impropers, &
               find_silica_residue=have_silica_potential,form_bond=form_bond,break_bond=break_bond, &
               silica_pos_dep_charges=silica_pos_dep_charges, silica_charge_transfer=silica_charge_transfer, &
               have_titania_potential=have_titania_potential, remove_Si_H_silica_bonds=remove_Si_H_silica_bonds, &
               remove_Ti_H_titania_bonds=remove_Ti_H_titania_bonds)
      end if
    end if

    if (trim(run_type) == 'QMMM' .and. trim(qmmm_link_type) == "QM_KIND") then
       if (trim(qmmm_link_qm_kind) == '') then
          RAISE_ERROR("qmmm_link_type == QM_KIND, but qmmm_link_qm_kind not specified", error)
       end if

       ! If we remove the QM-MM link bonds then QM and MM regions will be disconnected.
       ! We need to make QM region a separate molecule so that CP2K doesn't complain
       ! about discontigous molecules.

       call assign_property_pointer(at, 'cluster_mark'//trim(run_suffix), cluster_mark_p, error=error)
       PASS_ERROR(error)
       call assign_property_pointer(at, 'mol_id', mol_id_p, error=error)
       PASS_ERROR(error)
       qm_mol_id = maxval(mol_id_p) + 1
       do i=1,at%n
          if (cluster_mark_p(i) /= HYBRID_NO_MARK) mol_id_p(i) = qm_mol_id
       end do
    end if

    call do_cp2k_atoms_sort(at, sort_index_p, rev_sort_index, psf_print, topology_suffix, &
         tmp_run_dir, tmp_run_dir_i, form_bond, break_bond, intrares_impropers, &
         use_MM, have_silica_potential, have_titania_potential, error=error)
    PASS_ERROR_WITH_INFO("Failed to sort atoms in do_cp2k_calc", error)

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    allocate(qm_list_a(0), old_qm_list_a(0))
    allocate(link_list_a(0))
    allocate(old_link_list_a(0))
    allocate(qm_and_link_list_a(0))
   if (use_QMMM) then
      call get_qm_list(at, use_buffer, trim(run_suffix), trim(link_template_file), qm_list, old_qm_list, qm_list_a, old_qm_list_a, &
		       link_list_a, old_link_list_a, qm_and_link_list_a, rev_sort_index, cut_bonds, cut_bonds_p, old_cut_bonds, old_cut_bonds_p, &
		       link_template_a, link_template_n_lines, qmmm_link_type, qmmm_link_qm_kind_z, error)
      PASS_ERROR(error)
   endif

    if (qm_list%N == at%N) then
      call print("WARNING: requested '"//trim(run_type)//"' but all atoms are in QM region, doing full QM run instead", PRINT_ALWAYS)
      run_type='QS'
      use_QM = .true.
      use_MM = .false.
      use_QMMM = .false.
      method = 'QS'
    endif
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    ! write PSF file, if requested
    if (run_type /= "QS") then
      if (trim(psf_print) == "DRIVER_PRINT_AND_SAVE") then
	! we should fail for persistent_already_started=T, but this should have been dealt with above
	if (has_property(at, 'avgpos')) then
	  call write_psf_file_arb_pos(at, "quip_cp2k"//trim(topology_suffix)//".psf", run_type_string=trim(run_type),intrares_impropers=intrares_impropers, &
	    add_silica_23body=have_silica_potential .and. silica_add_23_body, form_bond=form_bond,break_bond=break_bond, &
            remove_qmmm_link_bonds=trim(qmmm_link_type) == 'QM_KIND', run_suffix=run_suffix)
	else if (has_property(at, 'pos')) then
	  call print("WARNING: do_cp2k_calc using pos for connectivity.  avgpos is preferred but not found.")
	  call write_psf_file_arb_pos(at, "quip_cp2k"//trim(topology_suffix)//".psf", run_type_string=trim(run_type),intrares_impropers=intrares_impropers, &
	    add_silica_23body=have_silica_potential .and. silica_add_23_body, pos_field_for_connectivity='pos',  &
            form_bond=form_bond,break_bond=break_bond, remove_qmmm_link_bonds=trim(qmmm_link_type) == 'QM_KIND', run_suffix=run_suffix)
	else
	  RAISE_ERROR("do_cp2k_calc needs some pos field for connectivity (run_type='"//trim(run_type)//"' /= 'QS'), but found neither avgpos nor pos", error)
	endif
	! write sort order
	call initialise(rev_sort_index_io, "quip_rev_sort_index"//trim(topology_suffix), action=OUTPUT)
	call print(rev_sort_index, file=rev_sort_index_io)
	call finalise(rev_sort_index_io)
      endif
    endif
    call system_timer('do_cp2k_calc/make_psf')

    call system_timer('do_cp2k_calc/centre_cell')
    if (auto_centre) then
      if (qm_list%N > 0) then
	centre_pos = pbc_aware_centre(at%pos(:,qm_list_a), at%lattice, at%g)
      else
	centre_pos = pbc_aware_centre(at%pos, at%lattice, at%g)
      endif
      call print("centering got automatic center " // centre_pos, PRINT_VERBOSE)
    endif
    ! move specified centre to origin (centre is already 0 if not specified)
    at%pos(1,:) = at%pos(1,:) - centre_pos(1)
    at%pos(2,:) = at%pos(2,:) - centre_pos(2)
    at%pos(3,:) = at%pos(3,:) - centre_pos(3)
    ! move origin into center of CP2K box (0.5 0.5 0.5 lattice coords)
    call map_into_cell(at)

    if (.not. get_value(at%params, 'Periodic', at_periodic)) at_periodic = .true.
    if (.not. at_periodic) then
      cp2k_box_centre_pos(1:3) = 0.5_dp*sum(at%lattice,2)
      at%pos(1,:) = at%pos(1,:) + cp2k_box_centre_pos(1)
      at%pos(2,:) = at%pos(2,:) + cp2k_box_centre_pos(2)
      at%pos(3,:) = at%pos(3,:) + cp2k_box_centre_pos(3)
    endif
    call system_timer('do_cp2k_calc/centre_cell')

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    call system_timer('do_cp2k_calc/write_cp2k_input')
    if (.not. persistent_already_started) then
       call initialise(cp2k_input_io, trim(run_dir)//'/cp2k_input.inp.header',OUTPUT,append=.true.)

       if (do_calc_virial) then
	  call print("@SET DO_STRESS 1", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       else
	  call print("@SET DO_STRESS 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       endif

       if (use_QM) then
	 call print("@SET DO_DFT 1", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       else
	 call print("@SET DO_DFT 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       endif
       if (use_MM) then
	 call print("@SET DO_MM 1", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       else
	 call print("@SET DO_MM 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       endif
       if (use_QMMM) then
	 call print("@SET DO_QMMM 1", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       else
	 call print("@SET DO_QMMM 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       endif

       ! set variables having to do with periodic configs
       insert_pos = 0
       if (at_periodic) then
	 call print("@SET PERIODIC XYZ", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       else
	 call print("@SET PERIODIC NONE", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       endif
       call print("@SET CELL_SIZE_INT_1 "//int(norm(at%lattice(:,1))), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET CELL_SIZE_INT_2 "//int(norm(at%lattice(:,2))), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET CELL_SIZE_INT_3 "//int(norm(at%lattice(:,3))), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET CELL_SIZE_INT_ODD_1 "//(int(norm(at%lattice(:,1))/2)*2+1), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET CELL_SIZE_INT_ODD_2 "//(int(norm(at%lattice(:,2))/2)*2+1), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET CELL_SIZE_INT_ODD_3 "//(int(norm(at%lattice(:,3))/2)*2+1), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET MAX_CELL_SIZE_INT "//int(max(norm(at%lattice(:,1)),norm(at%lattice(:,2)), norm(at%lattice(:,3)))), &
	    file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET MAX_CELL_SIZE_INT_ODD "//(int(max(norm(at%lattice(:,1)),norm(at%lattice(:,2)), norm(at%lattice(:,3)))/2)*2+1), &
	    file=cp2k_input_io, verbosity=PRINT_ALWAYS)

       ! put in method
       call print("@SET FORCE_EVAL_METHOD "//trim(method), file=cp2k_input_io, verbosity=PRINT_ALWAYS)

       can_reuse_wfn = .true.

       call print("@SET DO_QMMM_LINK 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET QMMM_QM_KIND_FILE no_such_file", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       ! put in things needed for QMMM
       if (use_QMMM) then

	 call print('INFO: The size of the QM cell is either the MM cell itself, or it will have at least '//(qm_vacuum/2.0_dp)// &
			   ' Angstrom around the QM atoms.')
	 call print('WARNING! Please check if your cell is centreed around the QM region!',PRINT_ALWAYS)
	 call print('WARNING! CP2K centreing algorithm fails if QM atoms are not all in the',PRINT_ALWAYS)
	 call print('WARNING! 0,0,0 cell. If you have checked it, please ignore this message.',PRINT_ALWAYS)
         if (qmmm_same_lattice) then
            if (.not. at%is_orthorhombic) then
               RAISE_ERROR("qmmm_same_lattice=T but original at%lattice is not orthorhombic", error)
            end if
            cur_qmmm_qm_abc(1) = at%lattice(1,1)
            cur_qmmm_qm_abc(2) = at%lattice(2,2)
            cur_qmmm_qm_abc(3) = at%lattice(3,3)
         else
            cur_qmmm_qm_abc = qmmm_qm_abc(at, qm_list_a, qm_vacuum)
         end if
	 call print("@SET QMMM_ABC_X "//cur_qmmm_qm_abc(1), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 call print("@SET QMMM_ABC_Y "//cur_qmmm_qm_abc(2), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 call print("@SET QMMM_ABC_Z "//cur_qmmm_qm_abc(3), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 call print("@SET QMMM_PERIODIC XYZ", file=cp2k_input_io, verbosity=PRINT_ALWAYS)

	 if (get_value(at%params, "QM_cell"//trim(run_suffix), old_qmmm_qm_abc)) then
	   if (cur_qmmm_qm_abc .fne. old_qmmm_qm_abc) can_reuse_wfn = .false.
	 else
	   can_reuse_wfn = .false.
	 endif
	 call set_value(at%params, "QM_cell"//trim(run_suffix), cur_qmmm_qm_abc)
	  call print('set_value QM_cell'//trim(run_suffix)//' '//cur_qmmm_qm_abc)

	  ! check if QM list changed: compare cluster_mark and old_cluster_mark[_suffix]
	  ! if no old_cluster_mark, assumed it's changed just to be safe
	  qm_list_changed = .false.
	  if (.not.has_property(at, 'cluster_mark'//trim(run_suffix))) then
	    RAISE_ERROR('no cluster_mark'//trim(run_suffix)//' found in atoms object',error)
	  endif
	  if (.not.has_property(at, 'old_cluster_mark'//trim(run_suffix))) then
	    qm_list_changed = .true.
	  endif
	  dummy = assign_pointer(at, 'cluster_mark'//trim(run_suffix), cluster_mark_p)

	  if (.not. qm_list_changed) then
             dummy = assign_pointer(at, 'old_cluster_mark'//trim(run_suffix), old_cluster_mark_p)
	     do i=1,at%N
		if (old_cluster_mark_p(i) /= cluster_mark_p(i)) then ! mark changed.  Does it matter?
		    if (use_buffer) then ! EXTENDED, check for transitions to/from HYBRID_NO_MARK
		      if (any((/old_cluster_mark_p(i),cluster_mark_p(i)/) == HYBRID_NO_MARK)) qm_list_changed = .true.
		    else ! CORE, check for transitions between ACTIVE/TRANS and other
		      if ( ( any(old_cluster_mark_p(i)  == (/ HYBRID_ACTIVE_MARK, HYBRID_TRANS_MARK /)) .and. &
			     all(cluster_mark_p(i) /= (/ HYBRID_ACTIVE_MARK, HYBRID_TRANS_MARK /)) ) .or. &
			   ( any(cluster_mark_p(i)  == (/ HYBRID_ACTIVE_MARK, HYBRID_TRANS_MARK /)) .and. &
			     all(old_cluster_mark_p(i) /= (/ HYBRID_ACTIVE_MARK, HYBRID_TRANS_MARK /)) ) ) qm_list_changed = .true.
		    endif
		    if (qm_list_changed) exit
		endif
	     enddo
	  endif
	  call set_value(at%params,'QM_list_changed',qm_list_changed)
	  call print('set_value QM_list_changed '//qm_list_changed)

	  if (qm_list_changed) can_reuse_wfn = .false.

	 call initialise(cp2k_input_tmp_io, trim(run_dir)//'/cp2k_input.qmmm_qm_kind',OUTPUT)
	 call print("@SET QMMM_QM_KIND_FILE cp2k_input.qmmm_qm_kind", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 !Add QM atoms
	 counter = 0
         if (trim(qmmm_link_type) == "QM_KIND") then
            ! get unique list of inner link atoms - these are the atoms at boundary of QM region
            call uniq(cut_bonds%int(1,1:cut_bonds%N), inner_link_list_a)
            call print("&QM_KIND "//trim(qmmm_link_qm_kind), file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
            do i=1,size(inner_link_list_a)
               if (at%z(inner_link_list_a(i)) /= qmmm_link_qm_kind_z) then
                  RAISE_ERROR("QM_KIND boundary atom "//inner_link_list_a(i)//" has atomic number Z="//at%z(inner_link_list_a(i))//" != qmmm_link_qm_kind_z="//qmmm_link_qm_kind_z, error)
               end if
               call print("  MM_INDEX "//inner_link_list_a(i), file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
               counter = counter + 1
            end do
            call print("&END QM_KIND", file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
            deallocate(inner_link_list_a)
         end if
	 do at_Z=minval(at%Z), maxval(at%Z)
	   if (any(at%Z(qm_list_a) == at_Z)) then
	     call print("&QM_KIND "//trim(ElementName(at_Z)), file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
	     do i=1, size(qm_list_a)
	       if (at%Z(qm_list_a(i)) == at_Z) then
                 if (trim(qmmm_link_type) == "QM_KIND") then
                    ! skip inner link atoms
                    if (is_in_array(cut_bonds%int(1,1:cut_bonds%N), qm_list_a(i))) cycle
                 end if
		 call print("  MM_INDEX "//qm_list_a(i), file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
		 counter = counter + 1
	       endif
	     end do
	     call print("&END QM_KIND", file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
	   end if
	 end do
	 call finalise(cp2k_input_tmp_io)
	 if (size(qm_list_a) /= counter) then
	   RAISE_ERROR("Number of QM list atoms " // size(qm_list_a) // " doesn't match number of QM_KIND atoms " // counter,error)
	 endif

	 !Add link sections from template file for each link
	 if (size(link_list_a).gt.0 .and. trim(qmmm_link_type) /= "QM_KIND") then
	    call print("@SET DO_QMMM_LINK 1", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	    call print("@SET QMMM_LINK_FILE cp2k_input.link", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	    call initialise(cp2k_input_tmp_io, trim(run_dir)//'/cp2k_input.link',OUTPUT)
	    do i=1,cut_bonds%N
	       i_inner = cut_bonds%int(1,i)
	       i_outer = cut_bonds%int(2,i)
	       do i_line=1,link_template_n_lines
		  call print(trim(link_template_a(i_line)), file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
		  if (i_line == 1) then
		     call print("MM_INDEX "//i_outer, file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
		     call print("QM_INDEX "//i_inner, file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
		  endif
	       enddo
	    enddo
	    call finalise(cp2k_input_tmp_io)

            ! check if set of cut bonds has changed
            qmmm_link_list_changed = .false.
            if (cut_bonds%N > 0 .and. old_cut_bonds%N > 0) then
               do i=1,at%N
                  if (any(cut_bonds_p(:,i) /= old_cut_bonds_p(:,i))) then
                     qmmm_link_list_changed = .true.
                     exit
                  end if
               end do
               if (qmmm_link_list_changed) can_reuse_wfn = .false.
            end if

	 endif ! size(link_list_a) > 0
       endif ! use_QMMM

       call print("@SET WFN_FILE_NAME no_such_file", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET DO_DFT_LSD 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET DO_DFT_QM_CHARGES 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       ! put in things needed for QM
       if (use_QM) then
          
          if (trim(qmmm_link_type) == "QM_KIND") then
             old_n_hydrogen = 0
             n_hydrogen = 0
             old_n_extra_electrons = qmmm_link_n_electrons*old_cut_bonds%N
             n_extra_electrons = qmmm_link_n_electrons*cut_bonds%N
          else
             old_n_hydrogen = old_cut_bonds%N
             n_hydrogen = cut_bonds%N
             old_n_extra_electrons = 0
             n_extra_electrons = 0
          end if

          call calc_charge_lsd(at, old_qm_list_a, old_charge, old_do_lsd, n_hydrogen=old_n_hydrogen, &
               hydrogen_charge=hydrogen_charge, n_extra_electrons=old_n_extra_electrons, &
               use_mm_charges=qmmm_use_mm_charges, error=error)
          PASS_ERROR(error)
          call calc_charge_lsd(at, qm_list_a, charge, do_lsd, n_hydrogen=n_hydrogen, &
               hydrogen_charge=hydrogen_charge, n_extra_electrons=n_extra_electrons, &
               use_mm_charges=qmmm_use_mm_charges, error=error)
          PASS_ERROR(error)

         if (old_charge /= charge) can_reuse_wfn = .false.
         if (old_do_lsd .neqv. do_lsd) can_reuse_wfn = .false.
         call print('Setting DFT charge to '//charge//' and LSD to '//do_lsd)
	 call print("@SET DFT_CHARGE "//charge, file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 if (do_lsd) then
	    call print("@SET DO_DFT_LSD 1", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 endif
	 if (len_trim(calc_qm_charges) > 0) then
	    call print("@SET DO_DFT_QM_CHARGES 1", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 endif
	 if (try_reuse_wfn .and. can_reuse_wfn) then            
           call print('Reusing wavefunction from last time')
	   if (persistent) then
	      call print("@SET WFN_FILE_NAME quip-RESTART.wfn", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	   else
	      call print("@SET WFN_FILE_NAME ../wfn.restart.wfn"//trim(run_suffix), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	   endif
	   !insert_pos = find_make_cp2k_input_section(cp2k_template_a, template_n_lines, "&FORCE_EVAL&DFT", "&SCF")
	   !call insert_cp2k_input_line(cp2k_template_a, "&FORCE_EVAL&DFT&SCF SCF_GUESS RESTART", after_line = insert_pos, n_l = template_n_lines); insert_pos = insert_pos + 1
	 endif
       endif ! use_QM

       if (have_silica_potential .and. .not. silica_pos_dep_charges) then
          call print("@SET SIO_CHARGE "//silicon_charge, file=cp2k_input_io, verbosity=PRINT_ALWAYS)
          call print("@SET OSB_CHARGE "//oxygen_charge, file=cp2k_input_io, verbosity=PRINT_ALWAYS)
          call print("@SET HSI_CHARGE "//hydrogen_charge, file=cp2k_input_io, verbosity=PRINT_ALWAYS)
          call print("@SET OSTAR_CORE_CORRECTION "//(1.0_dp - silicon_charge/4.0_dp), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       end if

       ! put in unit cell
       call print("@SET SUBSYS_CELL_A_X "//at%lattice(1,1), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET SUBSYS_CELL_A_Y "//at%lattice(2,1), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET SUBSYS_CELL_A_Z "//at%lattice(3,1), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET SUBSYS_CELL_B_X "//at%lattice(1,2), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET SUBSYS_CELL_B_Y "//at%lattice(2,2), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET SUBSYS_CELL_B_Z "//at%lattice(3,2), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET SUBSYS_CELL_C_X "//at%lattice(1,3), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET SUBSYS_CELL_C_Y "//at%lattice(2,3), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET SUBSYS_CELL_C_Z "//at%lattice(3,3), file=cp2k_input_io, verbosity=PRINT_ALWAYS)

       ! put in topology
       call print("@SET ISOLATED_ATOMS_FILE cp2k_input.isolated_atoms", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call initialise(cp2k_input_tmp_io, trim(run_dir)//'/cp2k_input.isolated_atoms',OUTPUT)
       if (use_QMMM) then
	 do i=1, size(qm_list_a)
	   call print("LIST " // qm_list_a(i), file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
	 end do
       endif
       if (assign_pointer(at, "isolated_atom", isolated_atom)) then
	 do i=1, at%N
	   if (isolated_atom(i) /= 0) then
	     call print("LIST " // qm_list_a(i), file=cp2k_input_tmp_io, verbosity=PRINT_ALWAYS)
	   endif
	 end do
       endif
       call finalise(cp2k_input_tmp_io)

       call print("@SET COORD_FILE quip_cp2k.xyz", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET COORD_FORMAT XYZ", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       if (trim(psf_print) == "DRIVER_PRINT_AND_SAVE" .or. trim(psf_print) == "USE_EXISTING_PSF") then
	 call print("@SET USE_PSF 1", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 if (tmp_run_dir_i>0) then
	   call system_command("if [ ! -s "//trim(tmp_run_dir)//"/quip_cp2k"//trim(topology_suffix)//".psf ] ; then cp quip_cp2k"//trim(topology_suffix)//".psf /tmp/cp2k_run_"//tmp_run_dir_i//"/ ; fi",status=stat)
	   if ( stat /= 0 ) then
	     RAISE_ERROR("Something went wrong when tried to copy quip_cp2k"//trim(topology_suffix)//".psf into the tmp dir "//trim(tmp_run_dir),error)
	   endif
	   call print("@SET CONN_FILE quip_cp2k"//trim(topology_suffix)//".psf", file=cp2k_input_io, verbosity=PRINT_ALWAYS)

	 else
	   call print("@SET CONN_FILE ../quip_cp2k"//trim(topology_suffix)//".psf", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	 endif
	 call print("@SET CONN_FORMAT PSF", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       else
	 call print("@SET USE_PSF 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       endif

       ! put in global stuff to run a single force evalution, print out appropriate things
       call print("@SET QUIP_PROJECT "//trim(proj), file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET QUIP_RUN_TYPE MD", file=cp2k_input_io, verbosity=PRINT_ALWAYS)

       call print("@SET FORCES_FORMAT XMOL", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET PERSISTENT_TRAJ_FILE no_such_file", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       call print("@SET PERSISTENT_CELL_FILE no_such_file", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       if (persistent) then
	  call print("@SET QUIP_ENSEMBLE REFTRAJ", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	  call print("@SET QUIP_N_STEPS 100000000", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	  call print("@SET PERSISTENT_TRAJ_FILE quip.persistent.traj.xyz", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	  call print("@SET PERSISTENT_CELL_FILE quip.persistent.traj.cell", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       else
	  call print("@SET QUIP_ENSEMBLE NVE", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
	  call print("@SET QUIP_N_STEPS 0", file=cp2k_input_io, verbosity=PRINT_ALWAYS)
       endif

       call finalise(cp2k_input_io)
    endif
    call system_timer('do_cp2k_calc/write_cp2k_input')
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    call system_timer('do_cp2k_calc/write_xyz')
    if (at_periodic .and. size(link_list_a) > 0 .and. qmmm_link_fix_pbc) then
       ! correct position of OUTER atoms so no links cross a periodic boundary since
       ! if they did, CP2K would place terminating hydrogens incorrectly
       
       do i=1,cut_bonds%N
          i_inner = cut_bonds%int(1,i)
          i_outer = cut_bonds%int(2,i)
          
          disp = diff_min_image(at, i_inner, i_outer, shift=shift)
          if (any(shift /= 0)) then
             call print('Unwrapping QM/MM link '//i_inner//'-'//i_outer//' by shift '//shift)
             at%pos(:,i_outer) = at%pos(:,i_outer) + (at%lattice .mult. shift) 
          end if
       end do
    endif

    ! prepare xyz file for input to cp2k
    if (persistent) then
       ! write cell file
       call initialise(persistent_cell_file_io, trim(run_dir)//'/quip.persistent.traj.cell', OUTPUT, append=.false.)
       call print("0 0.0 "//at%lattice(:,1)//" "//at%lattice(:,2)//" "//at%lattice(:,3)//" "//cell_volume(at), file=persistent_cell_file_io, verbosity=PRINT_ALWAYS)
       call finalise(persistent_cell_file_io)
       ! write traj file
       call write(at, trim(run_dir)//'/quip.persistent.traj.xyz', append=.false., properties='species:pos')
       ! write initial config if needed
       if (.not. persistent_already_started) &
	  call write(at, trim(run_dir)//'/quip_cp2k.xyz', properties='species:pos')
       ! touch REFTRAJ_READY FILE
       call initialise(persistent_cell_file_io, trim(run_dir)//'/REFTRAJ_READY', OUTPUT, append=.true.)
       call print("go",file=persistent_cell_file_io)
       call finalise(persistent_cell_file_io)
    else
       call write(at, trim(run_dir)//'/quip_cp2k.xyz', properties='species:pos')
    endif
    call system_timer('do_cp2k_calc/write_xyz')

    ! actually run cp2k
    if (persistent) then
       call system_timer('do_cp2k_calc/run_cp2k')
       if (persistent_start_cp2k) then
	  call start_cp2k_program_background(trim(cp2k_program), trim(run_dir), error=error)
	  PASS_ERROR(error)
       endif
       wait_time = 0.0_dp
       do while(.true.)
	  inquire(file=trim(run_dir)//"/"//trim(proj)//"-frc-1_"//persistent_run_i//".xyz", exist=persistent_frc_exists)
	  if (persistent_frc_exists) then
	     ! inquire(file=trim(run_dir)//"/"//trim(proj)//"-frc-1_"//persistent_run_i//".xyz", size=persistent_frc_size)
	     persistent_frc_size = ffsize(trim(run_dir)//"/"//trim(proj)//"-frc-1_"//persistent_run_i//".xyz")
	     if (persistent_frc_size > 0) then ! got data, leave
		call fusleep(1000000)
		exit
	     else if (persistent_frc_size < 0) then ! error
	       RAISE_ERROR("Failed to get valid value from ffsize of "//trim(run_dir)//"/"//trim(proj)//"-frc-1_"//persistent_run_i//".xyz", error)
	     endif
	  endif
	  call fusleep(100000)
	  wait_time = wait_time + 100000_dp/1.0e6_dp
	  if (wait_time > persistent_max_wait_time) then
	     RAISE_ERROR("Failed to get forces after waiting at least "//persistent_max_wait_time//" s", error)
	  endif
       end do ! waiting for frc file
       call system_timer('do_cp2k_calc/run_cp2k')
       call system_timer('do_cp2k_calc/read_output')
       if (trim(qmmm_link_type) == 'QM_KIND') then
          call read_output(at, qm_list_a, cur_qmmm_qm_abc, trim(run_dir), trim(proj), e, f, trim(calc_qm_charges), &
               do_calc_virial,  save_reordering_index=.false., out_i=persistent_run_i, error=error)
       else
          call read_output(at, qm_and_link_list_a, cur_qmmm_qm_abc, trim(run_dir), trim(proj), e, f, trim(calc_qm_charges), &
               do_calc_virial,  save_reordering_index=.false., out_i=persistent_run_i, error=error)
       end if
       PASS_ERROR(error)
       call system_timer('do_cp2k_calc/read_output')
    else ! not persistent
       call system_timer('do_cp2k_calc/run_cp2k')
       call run_cp2k_program(trim(cp2k_program), trim(run_dir), max_n_tries, error=error)
       PASS_ERROR(error)
       call system_timer('do_cp2k_calc/run_cp2k')
       call system_timer('do_cp2k_calc/read_output')
       if (trim(qmmm_link_type) == 'QM_KIND') then
          call read_output(at, qm_list_a, cur_qmmm_qm_abc, trim(run_dir), trim(proj), e, f, trim(calc_qm_charges), &
               do_calc_virial,  save_reordering_index=.false., out_i=persistent_run_i, error=error)
       else
          call read_output(at, qm_and_link_list_a, cur_qmmm_qm_abc, trim(run_dir), trim(proj), e, f, trim(calc_qm_charges), &
               do_calc_virial,  save_reordering_index=.false., out_i=persistent_run_i, error=error)
       end if
       PASS_ERROR(error)
       call system_timer('do_cp2k_calc/read_output')
    endif

    call system_timer('do_cp2k_calc/process_output')
    at%pos(1,:) = at%pos(1,:) + centre_pos(1) - cp2k_box_centre_pos(1)
    at%pos(2,:) = at%pos(2,:) + centre_pos(2) - cp2k_box_centre_pos(2)
    at%pos(3,:) = at%pos(3,:) + centre_pos(3) - cp2k_box_centre_pos(3)
    call map_into_cell(at)

    ! unsort
    if (associated(sort_index_p)) then
      f(:,sort_index_p(:)) = f(:,:)
      call atoms_sort(at, 'sort_index', error=error)
      PASS_ERROR_WITH_INFO("do_cp2k_calc sorting atoms by sort_index",error)
    endif

    if (maxval(abs(f)) > max_force_warning) &
      call print('WARNING cp2k forces max component ' // maxval(abs(f)) // ' at ' // maxloc(abs(f)) // &
		 ' exceeds warning threshold ' // max_force_warning, PRINT_ALWAYS)

    if(do_mom_cons) call sum0(f)

    ! save output

    if (use_QM) then
      call system_command('cp '//trim(run_dir)//'/quip-RESTART.wfn wfn.restart.wfn'//trim(run_suffix))
      if (save_output_wfn_files) then
	call system_command('cp '//trim(run_dir)//'/quip-RESTART.wfn run_'//run_dir_i//'_end.wfn.restart.wfn'//trim(run_suffix))
      endif
    endif

    if (save_output_files) then
      if (persistent) then
	 log_sys_command_str=' if [ ! -f cp2k_input_log ]; then cat '//trim(run_dir)//'/cp2k_input.inp >> cp2k_input_log; echo "##############" >> cp2k_input_log; fi;' // &
	   ' cat filepot.0.xyz >> cp2k_driver_in_log.xyz;' // &
	   ' cat '//trim(run_dir)//'/'//trim(proj)//'-frc-1_'//persistent_run_i//'.xyz'// ' >> cp2k_force_file_log;'
	 if (do_calc_virial) then
	    log_sys_command_str = trim(log_sys_command_str) //' cat '//trim(run_dir)//'/'//trim(proj)//'-stress-1_'//persistent_run_i//'.stress_tensor'// ' >> cp2k_stress_file_log'
	 endif
      else
	 log_sys_command_str= ' cat '//trim(run_dir)//'/cp2k_input.inp >> cp2k_input_log; echo "##############" >> cp2k_input_log;' // &
	   ' cat '//trim(run_dir)//'/cp2k_output.out >> cp2k_output_log; echo "##############" >> cp2k_output_log;' // &
	   ' cat filepot.xyz >> cp2k_driver_in_log.xyz;' // &
	   ' cat '//trim(run_dir)//'/'//trim(proj)//'-frc-1_0.xyz'// ' >> cp2k_force_file_log;'
	 if (do_calc_virial) then
	    log_sys_command_str = trim(log_sys_command_str) // ' cat '//trim(run_dir)//'/'//trim(proj)//'-stress-1_0.stress_tensor'// ' >> cp2k_stress_file_log'
	 endif
      endif
      call system_command(trim(log_sys_command_str))
    endif
    call system_timer('do_cp2k_calc/process_output')

    ! clean up
    call system_timer('do_cp2k_calc/cleanup')
    if (tmp_run_dir_i>0) then
      if (clean_up_files) then
         !only delete files that need recreating, keep basis, potentials, psf
         call system_command('rm -f '//trim(tmp_run_dir)//"/"//trim(proj)//"-* "//trim(tmp_run_dir)//"/cp2k_input.inp "//trim(tmp_run_dir)//"/cp2k_output.out "//trim(run_dir))
      else !save dir
         exists = .true.
         i = 0
         do while (exists)
           i = i + 1
           dir = "cp2k_run_saved_"//i
           call system_command("bash -c '[ -e "//trim(dir)//" ]'", status=stat)
           exists = (stat == 0)
         end do
         call system_command("cp -r "//trim(run_dir)//" "//trim(dir), status=stat)
         if (stat /= 0) then
            RAISE_ERROR("Failed to copy "//trim(run_dir)//" to "//trim(dir)//" status " // stat, error)
         endif
         call system_command('rm -f '//trim(tmp_run_dir)//"/* "//trim(run_dir))
      endif
    else
       if (clean_up_files) then
	 if (clean_up_keep_n <= 0) then ! never keep any old directories around
	    call system_command('rm -rf '//trim(run_dir))
	 else ! keep some (>= 1) old directories around
	    delete_dir_i = mod(run_dir_i, clean_up_keep_n+1)+1
	    call system_command('rm -rf cp2k_run_'//delete_dir_i)
	 endif
       endif
    endif
    if (allocated(rev_sort_index)) deallocate(rev_sort_index)
    call system_timer('do_cp2k_calc/cleanup')
    call system_timer('do_cp2k_calc')

    call verbosity_pop()

  end subroutine do_cp2k_calc

  subroutine do_cp2k_atoms_sort(at, sort_index_p, rev_sort_index, psf_print, topology_suffix, &
       tmp_run_dir, tmp_run_dir_i, form_bond, break_bond, intrares_impropers, &
       use_MM, have_silica_potential, have_titania_potential, error)
    type(Atoms), intent(inout) :: at
    integer, intent(out), pointer :: sort_index_p(:)
    integer, intent(inout), allocatable :: rev_sort_index(:)
    character(len=*), intent(in) :: psf_print
    character(len=*), intent(in) :: topology_suffix
    character(len=*), intent(in) :: tmp_run_dir
    integer, intent(in) :: tmp_run_dir_i
    integer :: form_bond(2), break_bond(2)
    type(Table), intent(inout) :: intrares_impropers
    logical, intent(in) :: use_MM, have_silica_potential, have_titania_potential
    integer, optional, intent(out) :: error

    logical :: sorted
    integer, pointer :: saved_rev_sort_index_p(:)
    type(inoutput) :: rev_sort_index_io
    integer :: at_i, iri_i
    integer :: stat

    ! sort by molecule, residue ID
    call add_property(at, 'sort_index', 0, n_cols=1, ptr=sort_index_p, error=error)
    PASS_ERROR_WITH_INFO("Failed to add sort_index property", error)
    ! initialise sort index
    do at_i=1, at%N
      sort_index_p(at_i) = at_i
    end do

    ! do sort by read in order or labels
    sorted = .false.
    if (trim(psf_print) == 'USE_EXISTING_PSF') then ! read sort order
       ! add property for saved reverse sort indx
       call add_property(at, 'saved_rev_sort_index', 0, n_cols=1, ptr=saved_rev_sort_index_p, error=error)
       PASS_ERROR_WITH_INFO("Failed to add saved_rev_sort_index property", error)
       ! read it from file
       if (tmp_run_dir_i>0) then
         call system_command("if [ ! -s "//trim(tmp_run_dir)//"/quip_rev_sort_index"//trim(topology_suffix)// &
	                     " ] ; then cp quip_rev_sort_index"//trim(topology_suffix)//" /tmp/cp2k_run_"//tmp_run_dir_i//"/ ; fi",status=stat)
         if ( stat /= 0 ) then
	    RAISE_ERROR("Something went wrong when tried to copy quip_rev_sort_index"//trim(topology_suffix)//" into the tmp dir "//trim(tmp_run_dir),error)
	 endif
         call initialise(rev_sort_index_io, trim(tmp_run_dir)//"/quip_rev_sort_index"//trim(topology_suffix), action=INPUT)
       else
         call initialise(rev_sort_index_io, "quip_rev_sort_index"//trim(topology_suffix), action=INPUT)
       endif
       call read_ascii(rev_sort_index_io, saved_rev_sort_index_p)
       call finalise(rev_sort_index_io)
       ! sort by it
       call atoms_sort(at, 'saved_rev_sort_index', error=error)
       PASS_ERROR_WITH_INFO ("do_cp2k_calc sorting atoms by read-in sort_index from quip_sort_order"//trim(topology_suffix), error)
       sorted = .true.
    endif
    if (trim(psf_print) == 'DRIVER_PRINT_AND_SAVE') then ! sort by labels
       if (has_property(at,'mol_id') .and. has_property(at,'atom_res_number')) then
	  if (has_property(at,'motif_atom_num')) then
	    call atoms_sort(at, 'mol_id', 'atom_res_number', 'motif_atom_num', error=error)
	  else
	    call atoms_sort(at, 'mol_id', 'atom_res_number', error=error)
	  endif
	  PASS_ERROR_WITH_INFO ("do_cp2k_calc sorting atoms by mol_id, atom_res_number, and motif_atom_num", error)
	  sorted = .true.
       endif
    endif
    
    if (allocated(rev_sort_index)) deallocate(rev_sort_index)
    allocate(rev_sort_index(at%N))
    do at_i=1, at%N
       rev_sort_index(sort_index_p(at_i)) = at_i
    end do

    if (sorted) then
      do at_i=1, at%N
	if (sort_index_p(at_i) /= at_i) then
	  call print("sort() of at%data reordered some atoms")
	  exit
	endif
      end do
      ! fix EVB bond forming/breaking indices for new sorted atom numbers
      if (use_MM) then
         if (have_silica_potential) then
            call set_cutoff(at,SILICA_2body_CUTOFF)
            call calc_connect(at)         
         elseif (have_titania_potential) then
            call set_cutoff(at,TITANIA_2body_CUTOFF)
            call calc_connect(at)
         else
            ! use hysteretic connect to get nearest neighbour cutoff
            call calc_connect_hysteretic(at, DEFAULT_NNEIGHTOL, DEFAULT_NNEIGHTOL)
         endif
         call map_into_cell(at)
         call calc_dists(at)
      endif

      if ((all(form_bond > 0) .and. all(form_bond <= at%N)) .or. (all(break_bond > 0) .and. all(break_bond <= at%N))) then
	 if (all(form_bond > 0) .and. all(form_bond <= at%N)) form_bond(:) = rev_sort_index(form_bond(:))
	 if (all(break_bond > 0) .and. all(break_bond <= at%N)) break_bond(:) = rev_sort_index(break_bond(:))
      end if
      ! fix intrares impropers atom indices for new sorted atom numbers
      do iri_i=1, intrares_impropers%N
	intrares_impropers%int(1:4,iri_i) = rev_sort_index(intrares_impropers%int(1:4,iri_i))
      end do
    else
      call print("WARNING: didn't do sort_by_molecule - need saved sort_index or mol_id, atom_res_number, motif_atom_num.  CP2K may complain", PRINT_ALWAYS)
    end if

  end subroutine do_cp2k_atoms_sort

  subroutine read_output(at, qm_list_a, cur_qmmm_qm_abc, run_dir, proj, e, f, calc_qm_charges, do_calc_virial, &
       save_reordering_index, out_i, error)
    type(Atoms), intent(inout) :: at
    integer, intent(in) :: qm_list_a(:)
    real(dp), intent(in) :: cur_qmmm_qm_abc(3)
    character(len=*), intent(in) :: run_dir, proj
    real(dp), intent(out) :: e, f(:,:)
    real(dp), pointer :: force_p(:,:)
    character(len=*) :: calc_qm_charges
    logical :: do_calc_virial, save_reordering_index
    integer, intent(in), optional :: out_i
    integer, intent(out), optional :: error

    integer, pointer :: reordering_index_p(:)
    real(dp), pointer :: qm_charges_p(:)
    real(dp) :: at_population, at_net_charge
    type(Atoms) :: f_xyz, p_xyz
    integer :: m
    integer :: i, at_i
    type(inoutput) :: t_io
    character(len=STRING_LENGTH) :: at_species, t_line
    integer :: at_kind
    integer :: use_out_i
    real(dp) :: virial(3,3)
    character :: tx, ty, tz
    integer :: istat

    INIT_ERROR(error)

    use_out_i = optional_default(0, out_i)

    call read(f_xyz, trim(run_dir)//'/'//trim(proj)//'-frc-1_'//use_out_i//'.xyz')
    call read(p_xyz, trim(run_dir)//'/'//trim(proj)//'-pos-1_'//use_out_i//'.xyz')
    nullify(qm_charges_p)
    if (len_trim(calc_qm_charges) > 0) then
      if (.not. assign_pointer(at, trim(calc_qm_charges), qm_charges_p)) then
	  call add_property(at, trim(calc_qm_charges), 0.0_dp, ptr=qm_charges_p)
      endif
      call initialise(t_io, trim(run_dir)//'/'//trim(proj)//'-qmcharges--1_'//use_out_i//'.mulliken',action=INPUT, error=error)
      PASS_ERROR_WITH_INFO("cp2k_driver read_output() failed to open qmcharges file", error)
      t_line=''
      do while (index(adjustl(t_line),"#") <= 0)
	t_line = read_line(t_io)
      end do
      do i=1, at%N
	t_line = read_line(t_io)
	read (unit=t_line,fmt=*) at_i, at_species, at_kind, at_population, at_net_charge
	qm_charges_p(i) = at_net_charge
      end do
      call finalise(t_io)
    endif
    if (do_calc_virial) then
      call initialise(t_io, trim(run_dir)//'/'//trim(proj)//'-stress-1_'//use_out_i//'.stress_tensor',action=INPUT, error=error)
      PASS_ERROR_WITH_INFO("cp2k_driver failed to read cp2k stress_tensor file", error)
      tx=''
      ty=''
      tz=''
      ! look for line with just 'X Y Z'
      t_line=read_line(t_io)
      read(unit=t_line, fmt=*, iostat=istat) tx, ty, tz
      do while (istat /= 0 .or. tx /= 'X' .or. ty /= 'Y' .or. tz /= 'Z')
	 t_line=read_line(t_io)
	 read(unit=t_line, fmt=*, iostat=istat) tx, ty, tz
      end do
      ! now let's ready stress
      t_line=read_line(t_io)
      read(unit=t_line, fmt=*, iostat=istat) tx, virial(1,1), virial(1,2), virial(1,3)
      if (istat /= 0) then
	 RAISE_ERROR("cp2k_driver failed to read virial(1,:)", error)
      endif
      t_line=read_line(t_io)
      read(unit=t_line, fmt=*, iostat=istat) tx, virial(2,1), virial(2,2), virial(2,3)
      if (istat /= 0) then
	 RAISE_ERROR("cp2k_driver failed to read virial(2,:)", error)
      endif
      t_line=read_line(t_io)
      read(unit=t_line, fmt=*, iostat=istat) tx, virial(3,1), virial(3,2), virial(3,3)
      if (istat /= 0) then
	 RAISE_ERROR("cp2k_driver failed to read virial(3,:)", error)
      endif
      call print("got cp2k stress(1,:) "//virial(1,:))
      call print("got cp2k stress(2,:) "//virial(2,:))
      call print("got cp2k stress(3,:) "//virial(3,:))
      ! convert from stress GPa to virial in native units
      virial = cell_volume(at)*virial/EV_A3_IN_GPA
      call set_value(at%params, 'virial', virial)
      call finalise(t_io)
    endif

    if (.not. get_value(f_xyz%params, "E", e)) then
      RAISE_ERROR('read_output failed to find E value in '//trim(run_dir)//'/'//trim(proj)//'-frc-1_'//use_out_i//'.xyz file', error)
    endif

    if (.not.(assign_pointer(f_xyz, 'frc', force_p))) then
      RAISE_ERROR("Did not find frc property in "//trim(run_dir)//'/'//trim(proj)//'-frc-1_'//use_out_i//'.xyz file', error)
    endif
    f = force_p

    nullify(reordering_index_p)
    if (save_reordering_index) then
       if (.not. assign_pointer(at, "reordering_index", reordering_index_p)) then
          call add_property(at, "reordering_index", 0, ptr=reordering_index_p)
       endif
    end if

    e = e * HARTREE
    f  = f * HARTREE/BOHR 
    call reorder_if_necessary(at, qm_list_a, cur_qmmm_qm_abc, p_xyz%pos, f, qm_charges_p, &
         reordering_index_p, error=error)
    PASS_ERROR_WITH_INFO("cp2k_driver read_output failed to reorder atmos", error)

    call print('')
    call print('The energy of the system: '//e)
    call verbosity_push_decrement()
      call print('The forces acting on each atom (eV/A):')
      call print('atom     F(x)     F(y)     F(z)')
      do m=1,size(f,2)
        call print('  '//m//'    '//f(1,m)//'  '//f(2,m)//'  '//f(3,m))
      enddo
    call verbosity_pop()
    call print('Sum of the forces: '//sum(f,2))

  end subroutine read_output

  subroutine reorder_if_necessary(at, qm_list_a, qmmm_qm_abc, new_p, new_f, qm_charges_p, &
       reordering_index_p, error)
    type(Atoms), intent(in) :: at
    integer, intent(in) :: qm_list_a(:)
    real(dp), intent(in) :: qmmm_qm_abc(3)
    real(dp), intent(in) :: new_p(:,:)
    real(dp), intent(inout) :: new_f(:,:)
    real(dp), intent(inout), pointer :: qm_charges_p(:)
    integer, intent(out), pointer :: reordering_index_p(:)
    integer, optional, intent(out) :: error

    real(dp) :: shift(3)
    integer, allocatable :: reordering_index(:)
    integer :: i

    INIT_ERROR(error)

    ! shifted cell in case of QMMM (cp2k/src/topology_coordinate_util.F)
    shift = 0.0_dp
    if (size(qm_list_a) > 0) then
      do i=1,3
	shift(i) = 0.5_dp * qmmm_qm_abc(i) - (minval(at%pos(i,qm_list_a)) + maxval(at%pos(i,qm_list_a)))*0.5_dp
      end do
    endif
    allocate(reordering_index(at%N))
    call print('trying to reorder with shift='//shift)
    call system_timer('reorder_if_necessary/check_reordering_1')
    call check_reordering(at%pos, shift, new_p, at%g, reordering_index)
    call system_timer('reorder_if_necessary/check_reordering_1')
    if (any(reordering_index == 0)) then
      ! try again with shift of a/2 b/2 c/2 in case TOPOLOGY%CENTER_COORDINATES is set
      shift = sum(at%lattice(:,:),2)/2.0_dp - &
	      (minval(at%pos(:,:),2)+maxval(at%pos(:,:),2))/2.0_dp
      call print('trying to reorder with shift='//shift)
      call system_timer('reorder_if_necessary/check_reordering_2')
      call check_reordering(at%pos, shift, new_p, at%g, reordering_index)
      call system_timer('reorder_if_necessary/check_reordering_2')
      if (any(reordering_index == 0)) then
	! try again with uniform shift (module periodic cell)
	shift = new_p(:,1) - at%pos(:,1)
        call print('trying to reorder with shift='//shift)
        call system_timer('reorder_if_necessary/check_reordering_3')
	call check_reordering(at%pos, shift, new_p, at%g, reordering_index)
        call system_timer('reorder_if_necessary/check_reordering_3')
	if (any(reordering_index == 0)) then
	  RAISE_ERROR("Could not match original and read in atom objects",error)
	endif
      endif
    endif

    do i=1, at%N
      if (reordering_index(i) /= i) then
	 call print("WARNING: reorder_if_necessary indeed found reordered atoms", PRINT_ALWAYS)
	 exit
      endif
    end do

    if (associated(reordering_index_p)) then
       if (size(reordering_index_p) < size(reordering_index)) then
          RAISE_ERROR("save_reordering_index too small", error)
       end if
       reordering_index_p(1:size(reordering_index)) = reordering_index
    end if

    new_f(1,reordering_index(:)) = new_f(1,:)
    new_f(2,reordering_index(:)) = new_f(2,:)
    new_f(3,reordering_index(:)) = new_f(3,:)
    if (associated(qm_charges_p)) then
      qm_charges_p(reordering_index(:)) = qm_charges_p(:)
    endif

    deallocate(reordering_index)
  end subroutine reorder_if_necessary

  subroutine check_reordering(old_p, shift, new_p, recip_lattice, reordering_index)
    real(dp), intent(in) :: old_p(:,:), shift(3), new_p(:,:), recip_lattice(3,3)
    integer, intent(out) :: reordering_index(:)

    integer :: N, i, j
    real(dp) :: dpos(3), dpos_i(3)

    N = size(old_p,2)

    reordering_index = 0
    do i=1, N
      ! check for same-order
      j = i
      dpos = matmul(recip_lattice(1:3,1:3), old_p(1:3,i) + shift(1:3) - new_p(1:3,j))
      dpos_i = nint(dpos)
      if (all(abs(dpos-dpos_i) <= 1.0e-4_dp)) then
        reordering_index(i) = j
      else ! not same order, search
	 do j=1, N
	   dpos = matmul(recip_lattice(1:3,1:3), old_p(1:3,i) + shift(1:3) - new_p(1:3,j))
	   dpos_i = nint(dpos)
	   if (all(abs(dpos-dpos_i) <= 1.0e-4_dp)) then
	     reordering_index(i) = j
	     exit
	   endif
	 end do
       end if
    end do
  end subroutine check_reordering

  subroutine start_cp2k_program_background(cp2k_program, run_dir, error)
    character(len=*), intent(in) :: cp2k_program, run_dir
    integer, optional, intent(out) :: error

    character(len=STRING_LENGTH) :: cp2k_run_command
    integer :: stat

    INIT_ERROR(error)

    cp2k_run_command = 'cd ' // trim(run_dir)//'; '//trim(cp2k_program)//' cp2k_input.inp >> cp2k_output.out &'
    call print("Doing '"//trim(cp2k_run_command)//"'")
    call system_command(trim(cp2k_run_command), status=stat)
    if (stat /= 0) then
      RAISE_ERROR("failed to start cp2k program in the background", error)
    endif
  end subroutine start_cp2k_program_background

  subroutine run_cp2k_program(cp2k_program, run_dir, max_n_tries, error)
    character(len=*), intent(in) :: cp2k_program, run_dir
    integer, intent(in) :: max_n_tries
    integer, optional, intent(out) :: error

    integer :: n_tries
    logical :: converged
    character(len=STRING_LENGTH) :: cp2k_run_command
    integer :: stat, stat2, error_stat

    INIT_ERROR(error)

    n_tries = 0
    converged = .false.

    do while (.not. converged .and. (n_tries < max_n_tries))
      n_tries = n_tries + 1

      cp2k_run_command = 'cd ' // trim(run_dir)//'; '//trim(cp2k_program)//' cp2k_input.inp >> cp2k_output.out 2>&1'
      call print("Doing '"//trim(cp2k_run_command)//"'")
      call system_timer('cp2k_run_command')
      call system_command(trim(cp2k_run_command), status=stat)
      call system_timer('cp2k_run_command')
      call print('grep -i warning '//trim(run_dir)//'/cp2k_output.out', PRINT_ALWAYS)
      call system_command("fgrep -i 'warning' "//trim(run_dir)//"/cp2k_output.out")
      call system_command("fgrep -i 'error' "//trim(run_dir)//"/cp2k_output.out", status=error_stat)
      if (stat /= 0) then
	! RAISE_ERROR('cp2k_run_command has non zero return status ' // stat //'. check output file '//trim(run_dir)//'/cp2k_output.out', error)
	call print('WARNING: cp2k_run_command has non zero return status ' // stat //'. check output file '//trim(run_dir)//'/cp2k_output.out', error)
      endif
      if (error_stat == 0) then
	! RAISE_ERROR('cp2k_run_command generated ERROR message in output file '//trim(run_dir)//'/cp2k_output.out', error)
	call print('WARNING: cp2k_run_command generated ERROR message in output file '//trim(run_dir)//'/cp2k_output.out', error)
      endif

      call system_command('egrep "QS" '//trim(run_dir)//'/cp2k_output.out',status=stat)
      if (stat == 0) then ! QS or QMMM run
	call system_command('grep "FAILED to converge" '//trim(run_dir)//'/cp2k_output.out',status=stat)
	if (stat == 0) then
	  call print("WARNING: cp2k_driver failed to converge, trying again",PRINT_ALWAYS)
	  converged = .false.
	else
	  call system_command('grep "outer SCF loop converged" '//trim(run_dir)//'/cp2k_output.out',status=stat) ! OT mode
	  call system_command('grep "SCF run converged" '//trim(run_dir)//'/cp2k_output.out',status=stat2)       ! density mixing mode
	  if (stat == 0 .or. stat2 == 0) then
	    converged = .true.
	  else
	    call print("WARNING: cp2k_driver couldn't find definitive sign of convergence or failure to converge in output file, trying again",PRINT_ALWAYS)
	    converged = .false.
	  endif
	end if
      else ! MM run
	converged = .true.
      endif
    end do

    if (.not. converged) then
      RAISE_ERROR('cp2k failed to converge after n_tries='//n_tries//'. see output file '//trim(run_dir)//'/cp2k_output.out',error)
    endif

  end subroutine run_cp2k_program

  function qmmm_qm_abc(at, qm_list_a, qm_vacuum)
    type(Atoms), intent(in) :: at
    integer, intent(in) :: qm_list_a(:)
    real(dp), intent(in) :: qm_vacuum
    real(dp) :: qmmm_qm_abc(3)

    real(dp) :: qm_maxdist(3)
    integer i, j

    qm_maxdist = 0.0_dp
    do i=1, size(qm_list_a)
    do j=1, size(qm_list_a)
      qm_maxdist(1) = max(qm_maxdist(1), at%pos(1,qm_list_a(i))-at%pos(1,qm_list_a(j)))
      qm_maxdist(2) = max(qm_maxdist(2), at%pos(2,qm_list_a(i))-at%pos(2,qm_list_a(j)))
      qm_maxdist(3) = max(qm_maxdist(3), at%pos(3,qm_list_a(i))-at%pos(3,qm_list_a(j)))
    end do
    end do

    qmmm_qm_abc(1) = min(real(ceiling(qm_maxdist(1)))+qm_vacuum,at%lattice(1,1))
    qmmm_qm_abc(2) = min(real(ceiling(qm_maxdist(2)))+qm_vacuum,at%lattice(2,2))
    qmmm_qm_abc(3) = min(real(ceiling(qm_maxdist(3)))+qm_vacuum,at%lattice(3,3))

  end function qmmm_qm_abc

  subroutine calc_charge_lsd(at, qm_list_a, charge, do_lsd, n_hydrogen, hydrogen_charge, &
       n_extra_electrons, use_mm_charges, error)
    type(Atoms), intent(in) :: at
    integer, intent(in) :: qm_list_a(:)
    integer, intent(out) :: charge
    logical, intent(out) :: do_lsd
    integer, intent(in) :: n_hydrogen
    real(dp), intent(in) :: hydrogen_charge
    integer, intent(in) :: n_extra_electrons
    logical, intent(in) :: use_mm_charges
    integer, intent(out), optional :: error

    real(dp), pointer :: atom_charge(:)
    integer, pointer  :: Z_p(:)
    integer           :: sum_Z
    integer           :: l_error
    real(dp) :: sum_charge

    INIT_ERROR(error)

    if (.not. assign_pointer(at, "Z", Z_p)) then
	RAISE_ERROR("calc_charge_lsd could not find Z property", error)
    endif

    if (size(qm_list_a) > 0) then
      if (.not. assign_pointer(at, "atom_charge", atom_charge)) then
	RAISE_ERROR("calc_charge_lsd could not find atom_charge", error)
      endif
      sum_charge = 0.0_dp
      if (use_mm_charges) then
         sum_charge = sum(atom_charge(qm_list_a))
      end if
      call print('sum_charge before correction = '//sum_charge)
      if (use_mm_charges) then
         call print('n_hydrogen = '//n_hydrogen//', n_extra_electrons = '//n_extra_electrons)
         sum_charge = sum_charge + n_hydrogen*hydrogen_charge ! terminating hydrogens
      end if
      sum_charge = sum_charge - n_extra_electrons
      call print('sum_charge = '//sum_charge)
      charge = nint(sum_charge)
      
      !check if we have an odd number of electrons
      sum_Z = sum(Z_p(qm_list_a(1:size(qm_list_a))))
      sum_Z = sum_Z + n_hydrogen ! include terminating hydrogens
      call print('sum_Z = '//sum_Z)
      do_lsd = (mod(sum_Z-charge,2) /= 0)
    else
      sum_Z = sum(Z_p)
      do_lsd = .false.
      charge = 0 
      call get_param_value(at, 'LSD', do_lsd, error=l_error) ! ignore error
      CLEAR_ERROR(error)
      !if charge is saved, also check if we have an odd number of electrons
      call get_param_value(at, 'Charge', charge, error=l_error)
      CLEAR_ERROR(error)
      if (l_error == 0) then
        call print("Using Charge " // charge)
        do_lsd = do_lsd .or. (mod(sum_Z-charge,2) /= 0)
      else !charge=0 is assumed by CP2K
        do_lsd = do_lsd .or. (mod(sum_Z,2) /= 0)
      endif
      if (do_lsd) call print("Using do_lsd " // do_lsd)
    endif

  end subroutine calc_charge_lsd

  subroutine do_cp2k_calc_fake(at, f, e, do_calc_virial, args_str, error)
    type(Atoms), intent(inout) :: at
    real(dp), intent(out) :: f(:,:), e
    logical, intent(in) :: do_calc_virial
    character(len=*), intent(in) :: args_str
    integer, intent(out), optional :: error

    type(inoutput) :: last_run_io
    type(inoutput) :: stress_io
    type(cinoutput) :: force_cio
    character(len=STRING_LENGTH) :: last_run_s
    integer :: this_run_i
    integer :: stat
    type(Atoms) :: for
    real(dp), pointer :: frc(:,:)

    integer :: cur_i
    character(len=1024) :: l
    character t_s
    real(dp) :: virial(3,3)
    logical :: got_virial

    INIT_ERROR(error)

    call initialise(last_run_io, "cp2k_driver_fake_run", action=INPUT)
    last_run_s = read_line(last_run_io, status=stat)
    call finalise(last_run_io)
    if (stat /= 0) then
      this_run_i = 1
    else
      read (fmt=*,unit=last_run_s) this_run_i
      this_run_i = this_run_i + 1
    endif

    call print("do_cp2k_calc_fake run_i " // this_run_i, PRINT_ALWAYS)

    call initialise(force_cio, "cp2k_force_file_log")
    call read(force_cio, for, frame=this_run_i-1)
    !NB why does this crash now?
    ! call finalise(force_cio)
    if (.not. assign_pointer(for, 'frc', frc)) then
      RAISE_ERROR("do_cp2k_calc_fake couldn't find frc field in force log file",error)
    endif
    f = frc

    if (.not. get_value(for%params, "energy", e)) then
      if (.not. get_value(for%params, "Energy", e)) then
	if (.not. get_value(for%params, "E", e)) then
	  RAISE_ERROR("do_cp2k_calc_fake didn't find energy",error)
	endif
      endif
    endif

    if (do_calc_virial) then
       call initialise(stress_io, "cp2k_stress_file_log", action=INPUT)
       got_virial=.false.
       cur_i=0
       do while (.not. got_virial)
	  l=read_line(stress_io, status=stat)
	  if (stat /= 0) exit
	  if (index(trim(l), "STRESS TENSOR [GPa]") > 0) then
	    cur_i=cur_i + 1
	  endif
	  if (cur_i == this_run_i) then
	     if (index(trim(l), 'X') > 0 .and. index(trim(l), 'Y') <= 0) read(unit=l, fmt=*) t_s, virial(1,1), virial(1,2), virial(1,3)
	     if (index(trim(l), 'Y') > 0 .and. index(trim(l), 'X') <= 0) read(unit=l, fmt=*) t_s, virial(2,1), virial(2,2), virial(2,3)
	     if (index(trim(l), 'Z') > 0 .and. index(trim(l), 'Y') <= 0) then
	       read(unit=l, fmt=*) t_s, virial(3,1), virial(3,2), virial(3,3)
	       got_virial=.true.
	     endif
	  endif
       end do
       if (.not. got_virial) then
	 RAISE_ERROR("do_cp2k_calc_fake got do_calc_virial but couldn't read virial for config "//this_run_i//" from cp2k_stress_file_log",error)
       endif
       call print("got cp2k stress(1,:) "//virial(1,:))
       call print("got cp2k stress(2,:) "//virial(2,:))
       call print("got cp2k stress(3,:) "//virial(3,:))
       virial = cell_volume(at)*virial/EV_A3_IN_GPA
       call set_value(at%params, 'virial', virial)
       call finalise(stress_io)
    endif

    e = e * HARTREE
    f  = f * HARTREE/BOHR 

    call initialise(last_run_io, "cp2k_driver_fake_run", action=OUTPUT)
    call print(""//this_run_i, file=last_run_io)
    call finalise(last_run_io)

  end subroutine do_cp2k_calc_fake


   subroutine get_qm_list(at, use_buffer, run_suffix, link_template_file, qm_list, old_qm_list, qm_list_a, old_qm_list_a, &
			  link_list_a, old_link_list_a, qm_and_link_list_a, rev_sort_index, cut_bonds, cut_bonds_p, old_cut_bonds, old_cut_bonds_p, &
			  link_template_a, link_template_n_lines, qmmm_link_type, qmmm_link_qm_kind_z, error)
      type(Atoms), intent(inout) :: at
      logical, intent(in) :: use_buffer
      character(len=*), intent(in) :: run_suffix, link_template_file, qmmm_link_type
      type(Table), intent(inout) :: qm_list, old_qm_list
      integer, allocatable, intent(inout) :: qm_list_a(:), old_qm_list_a(:), link_list_a(:), old_link_list_a(:), qm_and_link_list_a(:)
      integer, intent(in) :: rev_sort_index(:)
      type(Table), intent(inout) :: cut_bonds, old_cut_bonds
      integer, pointer, intent(inout) :: cut_bonds_p(:,:), old_cut_bonds_p(:,:)
      character(len=STRING_LENGTH), allocatable, intent(inout) :: link_template_a(:)
      integer, intent(inout) :: link_template_n_lines
      integer, intent(in) :: qmmm_link_qm_kind_z
      integer, intent(out), optional :: error

      integer :: i_inner, i_outer, j
      type(Inoutput) :: link_template_io

      INIT_ERROR(error)

      ! get qm_list and link_list
      if (use_buffer) then
	call get_hybrid_list(at, qm_list, all_but_term=.true.,int_property="cluster_mark"//trim(run_suffix))
	call get_hybrid_list(at, old_qm_list, all_but_term=.true.,int_property="old_cluster_mark"//trim(run_suffix))
      else
	call get_hybrid_list(at, qm_list, active_trans_only=.true.,int_property="cluster_mark"//trim(run_suffix))
	call get_hybrid_list(at, old_qm_list, active_trans_only=.true.,int_property="old_cluster_mark"//trim(run_suffix))
      endif
      if (allocated(qm_list_a)) deallocate(qm_list_a)
      if (allocated(old_qm_list_a)) deallocate(old_qm_list_a)
      if (allocated(link_list_a)) deallocate(link_list_a)
      if (allocated(old_link_list_a)) deallocate(old_link_list_a)
      if (allocated(qm_and_link_list_a)) deallocate(qm_and_link_list_a)
      allocate(qm_list_a(qm_list%N), old_qm_list_a(old_qm_list%N))
      if (qm_list%N > 0) qm_list_a = int_part(qm_list,1)
      if (old_qm_list%N > 0) old_qm_list_a = int_part(old_qm_list,1)
      !get link list

       if (assign_pointer(at,'cut_bonds'//trim(run_suffix),cut_bonds_p)) then
	  call initialise(cut_bonds,2,0,0,0,0)
	  do i_inner=1,at%N
	     do j=1,size(cut_bonds_p,1) !MAX_CUT_BONDS
		if (cut_bonds_p(j,i_inner) == 0) exit
		! correct for new atom indices resulting from sorting of atoms
		i_outer = rev_sort_index(cut_bonds_p(j,i_inner))

                ! If we're doing QM_KIND linking, skip bonds which do not originate from the correct species
                if (trim(qmmm_link_type) == "QM_KIND" .and. at%Z(i_inner) /= qmmm_link_qm_kind_z) cycle
		call append(cut_bonds,(/i_inner,i_outer/))
	     enddo
	  enddo
	  if (cut_bonds%N > 0) then
	     call uniq(cut_bonds%int(2,1:cut_bonds%N),link_list_a)
	     allocate(qm_and_link_list_a(size(qm_list_a)+size(link_list_a)))
	     qm_and_link_list_a(1:size(qm_list_a)) = qm_list_a(1:size(qm_list_a))
	     qm_and_link_list_a(size(qm_list_a)+1:size(qm_list_a)+size(link_list_a)) = link_list_a(1:size(link_list_a))
	  else
	     allocate(link_list_a(0))
	     allocate(qm_and_link_list_a(size(qm_list_a)))
	     if (size(qm_list_a) > 0) qm_and_link_list_a = qm_list_a
	  endif
       else
	  allocate(qm_and_link_list_a(size(qm_list_a)))
	  if (size(qm_list_a) > 0) qm_and_link_list_a = qm_list_a
       endif

       call initialise(old_cut_bonds,2,0,0,0,0)
       if(assign_pointer(at, 'old_cut_bonds'//trim(run_suffix), old_cut_bonds_p)) then
	  do i_inner=1,at%N
	     do j=1,size(old_cut_bonds_p,1) !MAX_CUT_BONDS
		if (old_cut_bonds_p(j,i_inner) == 0) exit
		! correct for new atom indices resulting from sorting of atoms
		i_outer = rev_sort_index(old_cut_bonds_p(j,i_inner))
		call append(old_cut_bonds,(/i_inner,i_outer/))
	     enddo
	  enddo
       end if

       !If needed, read QM/MM link_template_file
       if (size(link_list_a) > 0 .and. trim(qmmm_link_type) /= "QM_KIND") then
	  if (trim(link_template_file).eq."") then
	    RAISE_ERROR("There are QM/MM links, but qmmm_link_template is not defined.",error)
	  endif
	  call initialise(link_template_io, trim(link_template_file), INPUT)
	  call read_file(link_template_io, link_template_a, link_template_n_lines)
	  call finalise(link_template_io)
       end if
   end subroutine get_qm_list


   subroutine cp2k_state_change(at, to, from_list, ignore_failure, error)
     type(Atoms), intent(inout) :: at
     character(len=*), intent(in) :: to, from_list(:)
     logical, optional, intent(in) :: ignore_failure
     integer, optional, intent(out) :: error
     
     character(STRING_LENGTH) :: from
     integer, pointer :: cluster_mark_from(:), cut_bonds_from(:,:), hybrid_mark_from(:)
     integer i
     real(dp) QM_cell(3)
     logical found, do_ignore_failure

     INIT_ERROR(error)
     do_ignore_failure = optional_default(.false., ignore_failure)

     found = .false.
     do i=1, size(from_list)
        if (assign_pointer(at, 'cluster_mark'//trim(from_list(i)), cluster_mark_from)) then
           from = from_list(i)
           found = .true.
           exit
        end if
     end do
     if (.not. do_ignore_failure .and. .not. found) then
        RAISE_ERROR('cp2k_state_change cannot find any previous states in from_list', error)
     end if

     call print('cp2k_state_change changing CP2K saved state from '//trim(from)//' to '//trim(to))
     call print('cp2k_state_change copying property cluster_mark'//trim(from)//' to cluster_mark'//trim(to))
     call add_property(at, 'cluster_mark'//trim(to), cluster_mark_from, overwrite=.true.)
     if (.not. assign_pointer(at, 'cut_bonds'//trim(from), cut_bonds_from)) then
        RAISE_ERROR('cp2k_state_change found cluster_mark'//trim(from)//'but not cut_bonds'//trim(from)//' - inconsistent!', error)
     end if
     call print('cp2k_state_change copying property cut_bonds'//trim(from)//' to cut_bonds'//trim(to))
     call add_property(at, 'cut_bonds'//trim(to), cut_bonds_from, overwrite=.true.)
     if (get_value(at%params, 'QM_cell'//trim(from), QM_cell)) then
        call print('cp2k_state_change set_value QM_cell'//trim(to)//' '//QM_cell)
        call set_value(at%params, 'QM_cell'//trim(to), QM_cell)
     end if
     if (.not. assign_pointer(at, 'hybrid_mark'//trim(from), hybrid_mark_from)) then
        RAISE_ERROR('cp2k_state_change found cluster_mark'//trim(from)//'but not hybrid_mark'//trim(from)//' - inconsistent!', error)
     end if
     call print('cp2k_state_change copying property hybrid_mark'//trim(from)//' to hybrid_mark'//trim(to))
     call add_property(at, 'hybrid_mark'//trim(to), hybrid_mark_from, overwrite=.true.)
     call print('cp2k_state_change executing "if [ -f wfn.restart.wfn'//trim(from)//' ] ; then cp wfn.restart.wfn'//trim(from)//' wfn.restart.wfn'//trim(to)//' ; fi "')
     call system_command('if [ -f wfn.restart.wfn'//trim(from)//' ] ; then cp wfn.restart.wfn'//trim(from)//' wfn.restart.wfn'//trim(to)//' ; fi')

   end subroutine cp2k_state_change

  !momentum conservation
  !   weighing function: 1 (simply subtract sumF/n)
  !?!   weighing function: m (keeping same acceleration on the atoms)
  subroutine sum0(force)

    real(dp), dimension(:,:), intent(inout) :: force
    integer   :: i
    real(dp)  :: sumF(3)

    do i = 1, size(force,2)
       sumF(1) = sum(force(1,1:size(force,2)))
       sumF(2) = sum(force(2,1:size(force,2)))
       sumF(3) = sum(force(3,1:size(force,2)))
    enddo

    if ((sumF(1).feq.0.0_dp).and.(sumF(2).feq.0.0_dp).and.(sumF(3).feq.0.0_dp)) then
       call print('cp2k_driver: Sum of the forces are zero.')
       return
    endif

    call print('cp2k_driver: Sum of the forces was '//sumF(1:3))
    sumF = sumF / size(force,2)

    do i = 1, size(force,2)
       force(1:3,i) = force(1:3,i) - sumF(1:3)
    enddo

    do i = 1, size(force,2)
       sumF(1) = sum(force(1,1:size(force,2)))
       sumF(2) = sum(force(2,1:size(force,2)))
       sumF(3) = sum(force(3,1:size(force,2)))
    enddo
    call print('cp2k_driver: Sum of the forces after mom.cons.: '//sumF(1:3))

  end subroutine sum0


end module cp2k_driver_module
