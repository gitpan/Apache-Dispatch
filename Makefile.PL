package Apache::Dispatch;

use ExtUtils::MakeMaker;
use Apache::ExtUtils qw(command_table);
use Apache::src ();
use strict;

require 5.005;

my @directives = (
  #-------------------------------------------------------------------
  # DispatchAllow takes a list of all the namespaces that are
  # ok to try and dispatch.  It can be general (like Apache) or
  # specific (like Apache::SomeClass)
  #-------------------------------------------------------------------
  { name         => 'DispatchAllow',
    errmsg       => 'namespaces allowed execution', 
    args_how     => 'ITERATE',
    req_override => 'RSRC_CONF', },

  #-------------------------------------------------------------------
  # DispatchDeny is used to _extend_ the namespaces of disallowed
  # dispatches.
  #-------------------------------------------------------------------
  { name         => 'DispatchDeny',
    errmsg       => 'namespaces denied execution', 
    args_how     => 'ITERATE',
    req_override => 'RSRC_CONF', },

  #-------------------------------------------------------------------
  # DispatchMode controls the safety level of the dispatcher
  # Safe:    dispatch only those methods whose namespace is
  #          specified by DispatchAllow and whose namespace is
  #          not one of those denied execution by DispatchDeny 
  #          internal directives
  # Brave:   dispatch any method except those with namespaces
  #          disallowed by DispatchDeny and internal directives
  # Foolish: dispatch any method
  #-------------------------------------------------------------------
  { name         => 'DispatchMode',
    errmsg       => 'choose one of: Safe, Brave, or Foolish', 
    args_how     => 'TAKE1',
    req_override => 'RSRC_CONF', },

  #------------------------------------------------------------------
  # DispatchMethod tries to avoid overhead by allowing the user
  # to specify whether to always imply Class->handler, or 
  # Class->method, or to determine it on its own
  #------------------------------------------------------------------
  { name         => 'DispatchMethod',
    errmsg       => 'choose one of: Handler, Subroutine, or Determine', 
    args_how     => 'TAKE1',
    req_override => 'RSRC_CONF', },
);

command_table(\@directives);

WriteMakefile(
  'NAME'         => __PACKAGE__,
  'VERSION_FROM' => 'Dispatch.pm',
  'INC'          => Apache::src->new->inc,
  'PREREQ_PM'    => { mod_perl         => 1.24, },
  'clean'        => { FILES => '*.xs*' },
);
