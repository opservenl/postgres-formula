{%- from "postgres/map.jinja" import postgres with context -%}

{%- set pkgs = [postgres.pkg] + postgres.pkgs_extra -%}

{%- if postgres.use_upstream_repo -%}

include:
  - postgres.upstream

{%- endif %}

# Install, configure and start PostgreSQL server

postgresql-server:
  pkg.installed:
    - pkgs: {{ pkgs }}
{%- if postgres.use_upstream_repo %}
    - refresh: True
    - require:
      - pkgrepo: postgresql-repo
{%- endif %}

{%- if 'bin_dir' in postgres %}

# Make server binaries available in $PATH

  {%- for bin in postgres.server_bins %}

    {%- set path = salt['file.join'](postgres.bin_dir, bin) %}

{{ bin }}:
  alternatives.install:
    - link: {{ salt['file.join']('/usr/bin', bin) }}
    - path: {{ path }}
    - priority: 30
    - onlyif: test -f {{ path }}
    - require:
      - pkg: postgresql-server

  {%- endfor %}

{%- endif %}

postgresql-cluster-prepared:
  cmd.run:
    - name: {{ postgres.prepare_cluster.command }}
    - cwd: /
    - runas: {{ postgres.prepare_cluster.user }}
    - env: {{ postgres.prepare_cluster.env|default({}) }}
    - unless:
      - {{ postgres.prepare_cluster.test }}
    - require:
      - pkg: postgresql-server

postgresql-config-dir:
  file.directory:
    - name: {{ postgres.conf_dir }}
    - user: {{ postgres.user }}
    - group: {{ postgres.group }}
    - makedirs: True
    - require:
      - cmd: postgresql-cluster-prepared

{%- if postgres.postgresconf %}

postgresql-conf:
  file.blockreplace:
    - name: {{ postgres.conf_dir }}/postgresql.conf
    - marker_start: "# Managed by SaltStack: listen_addresses: please do not edit"
    - marker_end: "# Managed by SaltStack: end of salt managed zone --"
    - content: |
        {{ postgres.postgresconf|indent(8) }}
    - show_changes: True
    - append_if_not_found: True
    - backup: {{ postgres.postgresconf_backup }}
    - require:
      - file: postgresql-config-dir
    - watch_in:
       - service: postgresql-running

{%- endif %}

postgresql-pg_hba:
  file.managed:
    - name: {{ postgres.conf_dir }}/pg_hba.conf
    - source: {{ postgres['pg_hba.conf'] }}
    - template: jinja
    - user: {{ postgres.user }}
    - group: {{ postgres.group }}
    - mode: 600
    - defaults:
        acls: {{ postgres.acls }}
    - require:
      - file: postgresql-config-dir

{%- for name, tblspace in postgres.tablespaces|dictsort() %}

postgresql-tablespace-dir-{{ name }}:
  file.directory:
    - name: {{ tblspace.directory }}
    - user: {{ postgres.user }}
    - group: {{ postgres.group }}
    - mode: 700
    - makedirs: True
    - recurse:
      - user
      - group

{%- endfor %}

{%- if grains['init'] != 'unknown' %}

postgresql-running:
  service.running:
    - name: {{ postgres.service }}
    - enable: True
    - reload: True
    - watch:
      - file: postgresql-pg_hba

{%- else %}

# An attempt to launch PostgreSQL with `pg_ctl` if Salt was unable to
# detect local init system (`service` module would fail in this case)

postgresql-start:
  cmd.run:
    - name: pg_ctl -D {{ postgres.conf_dir }} -l logfile start
    - runas: {{ postgres.user }}
    - unless:
      - ps -p $(head -n 1 {{ postgres.conf_dir }}/postmaster.pid) 2>/dev/null

# Try to enable PostgreSQL in "manual" way if Salt `service` state module
# is currently not available (e.g. during Docker or Packer build when is no init
# system running)

postgresql-enable:
  cmd.run:
  {%- if salt['file.file_exists']('/bin/systemctl') %}
    - name: systemctl enable {{ postgres.service }}
  {%- elif salt['cmd.which']('chkconfig') %}
    - name: chkconfig {{ postgres.service }} on
  {%- elif salt['file.file_exists']('/usr/sbin/update-rc.d') %}
    - name: update-rc.d {{ service }} defaults
  {%- else %}
    # Nothing to do
    - name: 'true'
  {%- endif %}
    - onchanges:
      - cmd: postgresql-start

{%- endif %}
