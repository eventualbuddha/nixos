_:

{
  # `virsh` with no --connect defaults to `qemu:///session`, the per-user
  # libvirt instance, which has its own (empty) set of domains. Every VM here
  # -- vxsuite included -- is defined in the system instance that
  # `virtualisation.libvirtd.enable` in hosts/common.nix runs, so a bare
  # `virsh dominfo vxsuite` failed with "failed to get domain" until this was
  # set.
  #
  # LIBVIRT_DEFAULT_URI rather than VIRSH_DEFAULT_CONNECT_URI: the latter is
  # read only by virsh, while this one is honored by virt-manager,
  # virt-install and virt-viewer too. Reaching the system instance needs
  # membership in the `libvirtd` group, which hosts/common.nix already grants.
  home.sessionVariables.LIBVIRT_DEFAULT_URI = "qemu:///system";
}
