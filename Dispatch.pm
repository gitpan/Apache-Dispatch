package Apache::Dispatch;

#---------------------------------------------------------------------
#
# usage: PerlFixupHandler Apache::Dispatch
#        
#---------------------------------------------------------------------

use Apache::Constants qw( OK DECLINED );
use Apache::Log;
use Apache::ModuleConfig;
use DynaLoader ();
use strict;

$Apache::Dispatch::VERSION = '0.01';

if ($ENV{MOD_PERL}) {
  no strict;
  @ISA = qw(DynaLoader);
  __PACKAGE__->bootstrap($VERSION);
}

# set debug level
#  0 - messages at info or debug log levels
#  1 - verbose output at info or debug log levels
#  2 - really verbose output at info or debug log levels
$Apache::Dispatch::DEBUG = 0;

sub handler {
#---------------------------------------------------------------------
# initialize request object and variables
#---------------------------------------------------------------------
  
  my $r            = shift;
  my $log          = $r->server->log;

  my $uri          = $r->uri;
  
  my $rc           = undef;
  my $dispatch     = undef;

#---------------------------------------------------------------------
# do some preliminary stuff...
#---------------------------------------------------------------------
  
  $log->info("Using Apache::Dispatch");

  $log->info("\tchecking $uri for possible dispatch...")
     if $Apache::Dispatch::DEBUG;

  # don't try to dispatch a real file, directory, or location
  if (-e $r->finfo || -d $r->finfo || $r->location) {
    $log->info("\t$uri seems to really exist...")
       if $Apache::Dispatch::DEBUG;
    $log->info("Exiting Apache::Dispatch");
    return DECLINED;
  }

  # if the uri contains any characters we don't like, forget about it
  if ($uri =~ m![^\w/-]!) {
    $log->info("\t$uri has bogus characters...")
       if $Apache::Dispatch::DEBUG;
    $log->info("Exiting Apache::Dispatch");
    return DECLINED;
  }


#---------------------------------------------------------------------
# get the configuration directives
#---------------------------------------------------------------------

  my $cfg          = Apache::ModuleConfig->get($r->server);

  if ($Apache::Dispatch::DEBUG > 1) {
    $log->info("\tapplying the following dispatch rules:" . 
               "\n\t\tDispatchDeny: " . (join ' ', @{$cfg->{_deny}}) . 
               "\n\t\tDispatchAllow: " . (join ' ', @{$cfg->{_allow}}) .
               "\n\t\tDispatchMethod: " . $cfg->{_method} .
               "\n\t\tDispatchMode: " . $cfg->{_mode});
  }

  my @allow        = @{$cfg->{_allow}};
  my @deny         = @{$cfg->{_deny}};
  my $method       = $cfg->{_method};
  my $mode         = $cfg->{_mode};

#---------------------------------------------------------------------
# first, translate the uri into the proper method call
#---------------------------------------------------------------------

  # change all the / to :: 
  (my $base        = $uri) =~ s!/!::!g;

  # now, strip off the leading ::, if any
  $base            =~ s/^:://;

  # and the trailing ::, if any
  $base            =~ s/::$//;

#---------------------------------------------------------------------
# apply the allow and deny rules to the base 
#---------------------------------------------------------------------

  if ($mode eq "SAFE") {
    $rc            = _check_deny($base, $log, @deny);
    
    if ($rc) {
      $log->info("\t$base denied by DispatchDeny")
         if $Apache::Dispatch::DEBUG;
      $log->info("Exiting Apache::Dispatch");
      return DECLINED;
    }
    else {
      $rc          = _check_allow($base, $log, @allow);
    }
  
    unless ($rc) {
      $log->info("\t$base not permitted by DispatchAllow")
        if $Apache::Dispatch::DEBUG;
      $log->info("Exiting Apache::Dispatch");
      return DECLINED;
    }

  }
  elsif ($mode eq "BRAVE") {
    $rc            = _check_deny($base, $log, @deny);

    if ($rc) {
      $log->info("\t$base denied by DispatchDeny")
         if $Apache::Dispatch::DEBUG;
      $log->info("Exiting Apache::Dispatch");
      return DECLINED;
    }
  }

  # nothing to check for fools...

#---------------------------------------------------------------------
# now, try to determine the correct method to call
#---------------------------------------------------------------------

  if ($method eq "HANDLER") {
    $dispatch      = "$base->handler";
    $rc            = _check_method($dispatch, $log);
  }        
  elsif ($method eq "SUBROUTINE") {
    ($dispatch = $base) =~ s/(.*)::([^:]+)+/$1\->$2/;
    $rc            = _check_method($dispatch, $log);
  }
  else {
    ($dispatch = $base) =~ s/(.*)::([^:]+)+/$1\->$2/;
    $rc          = _check_method($dispatch, $log);
    
    unless ($rc) {
      $dispatch      = "$base->handler";
      $rc            = _check_method($dispatch, $log);
    }
  }

  unless ($rc) {
    $log->info("\t$uri did not result in a valid method")
      if $Apache::Dispatch::DEBUG;
    $log->info("Exiting Apache::Dispatch");
    return DECLINED;
  }

  $log->info("\t$uri was translated into $dispatch")
     if $Apache::Dispatch::DEBUG;

#---------------------------------------------------------------------
# all tests pass, so push returned coderef onto the PerlHandler stack
#---------------------------------------------------------------------
  
  $r->handler('perl-script');
  $r->push_handlers(PerlHandler => $rc);
  
#---------------------------------------------------------------------
# wrap up...
#---------------------------------------------------------------------

  $log->info("Exiting Apache::Dispatch");

  return OK;
}

#---------------------------------------------------------------------
# internal and configuration subroutines
#---------------------------------------------------------------------

sub _check_method {
  my ($dispatch, $log) = @_;

  $log->info("\tchecking the validity of $dispatch")
     if $Apache::Dispatch::DEBUG > 1;

  # try some complecated trickery here...
  my $test_object = {};

  my ($class, $method) = split '->', $dispatch;

  bless $test_object, $class;
  my $test = $test_object->can($method);

  if ($test && $Apache::Dispatch::DEBUG > 1) {
    $log->info("\t$dispatch appears to be a valid method call");
  } elsif ($Apache::Dispatch::DEBUG > 1) {
    $log->info("\t$dispatch does not appear to be a valid method call");
  }

  return $test;  
}

sub _check_deny {
  my ($dispatch, $log, @deny) = @_;

  my $total             = 0;

  foreach my $match (@deny) {
    $log->info("\tchecking $dispatch against DispatchDeny rule $match")
      if $Apache::Dispatch::DEBUG > 1;

     $total++ if ($dispatch =~ m/^\Q$match/);
  }

  return $total;
}

sub _check_allow {
  my ($dispatch, $log, @allow) = @_;

  my $total             = 0;

  foreach my $match (@allow) {
    $log->info("\tchecking $dispatch against DispatchAllow rule $match")
      if $Apache::Dispatch::DEBUG > 1;

     $total++ if ($dispatch =~ m/^\Q$match/);
  }

  return $total;
}

# it doesn't make sense to create a dispatcher on anything other than
# on a per-server/vhost basis, but we need to make sure that each
# vhost can properly override the main server config

sub _new {
  return bless {}, shift;
}

sub SERVER_CREATE {
  my $class          = shift;
  my $self           = $class->_new;

  # merge the default _deny values with whatever is already defined
  my @core           = qw(CORE AUTOLOAD UNIVERSAL SUPER);
  my %union          = ();

  foreach my $key (@core, @{$self->{_deny}}) {
    $union{$key}++;
  }
  @{$self->{_deny}}  = keys %union;

  # for the others, just define some defaults
  $self->{_mode}   ||= "Safe";
  $self->{_method} ||= "Handler";

  return $self;
}

sub SERVER_MERGE {
  my ($parent, $current) = @_;
  my %new = (%$parent, %$current);

  return bless \%new, ref($parent);
}

sub DispatchAllow ($$@) {
  my ($cfg, $parms, $allow) = @_;
  my $scfg = Apache::ModuleConfig->get($parms->server);
  push @{$scfg->{_allow}}, $allow;
}

sub DispatchDeny ($$@) {
  my ($cfg, $parms, $deny) = @_;
  my $scfg = Apache::ModuleConfig->get($parms->server);
  push @{$scfg->{_deny}}, $deny;
}

sub DispatchMode ($$$) {
  my ($cfg, $parms, $arg) = @_;
  my $scfg = Apache::ModuleConfig->get($parms->server);
  if ($arg =~ m/^Safe|Brave|Foolish$/i) {
    $scfg->{_mode} = uc($arg);
  } else {
    die "Invalid DispatchMode $arg!";
  }
}

sub DispatchMethod ($$$) {
  my ($cfg, $parms, $arg) = @_;
  my $scfg = Apache::ModuleConfig->get($parms->server);
  if ($arg =~ m/^Handler|Subroutine|Determine$/i) {
    $scfg->{_method} = uc($arg);
  } else {
    die "Invalid DispatchMethod $arg!";
  }
}
1;

__END__

=head1 NAME

Apache::Dispatch - call PerlHandlers with the ease of CGI

=head1 SYNOPSIS

httpd.conf:

  PerlModule Apache::Dispatch
  PerlFixupHandler Apache::Dispatch

  DispatchMode Safe
  DispatchMethod Handler
  DispatchAllow Custom
  DispatchDeny Apache Protected

=head1 DESCRIPTION

Apache::Dispatch translates $r->uri into a class and method and runs
it as a PerlHandler.  Basically, this allows you to call PerlHandlers
as you would CGI scripts - from the browser - without having to load
your httpd.conf with a slurry of <Location> tags.

=head1 EXAMPLE

in httpd.conf:

  PerlModule Apache::Dispatch
  PerlFixupHandler Apache::Dispatch

  DispatchMode Safe
  DispatchMethod Handler
  DispatchAllow Test

in browser:
  http://localhost/Foo

the results are the same as if your httpd.conf looked like:
  <Location /Foo>
     SetHandler perl-script
     PerlHandler Foo
  </Location>

=head1 CONFIGURATION

All configuration directives apply on a per-server basis. 
Virtual Hosts inherit any directives from the main server or can
delcare their own.

  DispatchMode    - Safe:       allow only those methods whose
                                namespace is explitily allowed by 
                                DispatchAllow and explitily not
                                denied by DispatchDeny

                    Brave:      allow only those methods whose
                                namespace is explitily not denied by 
                                DispatchDeny 

                    Foolish:    allow any method

  DispatchMethod  - Handler:    assume the method name is handler(),
                                meaning that /Foo/Bar becomes
                                Foo::Bar->handler()

                    Subroutine: assume the method name is the last
                                part of the uri - /Foo/Bar becomes
                                Foo->Bar()

                    Determine:  the method may either be handler() or
                                the last part of the uri.  the last
                                part is checked first, so  this has
                                the additional benefit of allowing
                                both /Foo/Bar/handler and /Foo/Bar to
                                to call Foo::Bar::handler().
                                of course, if Foo->Bar() exists, that
                                will be called since it would be found
                                first.

  DispatchAllow   - a list of namespaces allowed execution according
                    to the above rules

  DispatchDeny    - a list of namespaces denied execution according
                    to the above rules

=head1 NOTES

Apache::Dispatch tries to be a bit intelligent about things.  If by
the time the uri reaches the fixup phase it can be mapped to a real
file, directory, or <Location> tag, Apache::Dispatch declines the
request.

DispatchDeny always includes the following namespaces:
  AUTOLOAD
  CORE
  SUPER
  UNIVERSAL

Like everything in perl, the package names are case sensitive relative
to $r->uri.

Verbose debugging is enabled by setting $Apache::Dispatch::DEBUG=1.
Very verbose debugging is enabled at 2.  To turn off all debug
information set your apache LogLevel directive above info level.

This is alpha software, and as such has not been tested on multiple
platforms or environments.  It requires PERL_INIT=1, PERL_LOG_API=1,
and maybe other hooks to function properly.

=head1 FEATURES/BUGS

DispatchDeny and DispatchAllow work, but not quite the way I want.
For instance, DispatchDeny Custom will deny to Customer:: methods,
while DispatchAllow Custom will allow Custom::Filter->handler() and
Custom->filter(), but deny Customer:: methods.  I think DistpatchAllow
has the proper behavior, but DispatchDeny may need to be changed.
Input is welcome.

=head1 SEE ALSO

perl(1), mod_perl(1), Apache(3), Apache::ModuleConfig(3)

=head1 AUTHOR

Geoffrey Young <geoff@cpan.org>

=head1 COPYRIGHT

Copyright 2000 Geoffrey Young - all rights reserved.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
