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

$Apache::Dispatch::VERSION = '0.02';

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
  
  my ($rc, $dispatch, $method, $coderef) = undef;

#---------------------------------------------------------------------
# do some preliminary stuff...
#---------------------------------------------------------------------
  
  $log->info("Using Apache::Dispatch");

  $log->info("\tchecking $uri for possible dispatch...")
     if $Apache::Dispatch::DEBUG;

  # DispatchBase and DispatchMethod are per-directory directives
  # DispatchMode, DispatchAllow, and DispatchDeny are per-server
  my $dcfg         = Apache::ModuleConfig->get($r);
  my $scfg         = Apache::ModuleConfig->get($r->server);

  # don't try to dispatch a real file, directory, or location other
  # than one explicity turned on by DispatchBase
  if (-e $r->finfo || -d $r->finfo || 
        ($r->location && !$dcfg->{_base})) {
    $log->info("\t$uri seems to really exist...")
       if $Apache::Dispatch::DEBUG;
    $log->info("Exiting Apache::Dispatch");
    return DECLINED;
  }

  # if the uri contains any characters we don't like, bounce
  if ($uri =~ m![^\w/-]!) {
    $log->info("\t$uri has bogus characters...")
       if $Apache::Dispatch::DEBUG;
    $log->info("Exiting Apache::Dispatch");
    return DECLINED;
  }

#---------------------------------------------------------------------
# find the proper base class and apply the appropriate dispatch rules
#---------------------------------------------------------------------

  # change all the / to :: 
  (my $base      = $uri) =~ s!/!::!g;

  # strip off the leading and trailing :: if any
  $base          =~ s/^::|::$//g;

  if ($r->location) {
  #-------------------------------------------------------------------
  # we are within a <Location> containing DispatchBase
  #-------------------------------------------------------------------

    if ($Apache::Dispatch::DEBUG > 1) {
      $log->info("\tapplying the following dispatch rules:" . 
         "\n\t\tDispatchMethod: " . $dcfg->{_method} .
         "\n\t\tDispatchBase: " . $dcfg->{_base});
    } 

    (my $location = $r->location) =~ s!/!!;
    $base          =~ s/^$location/$dcfg->{_base}/e;

    $method        = $dcfg->{_method};

    unless ($base =~ m/::/) {
      $log->info("\tnull dispatch not allowed with DispatchBase...")
        if $Apache::Dispatch::DEBUG;
     $log->info("Exiting Apache::Dispatch");
      return DECLINED;
    }
  }
  else {
  #-------------------------------------------------------------------
  # we are outside a <Location> containing DispatchBase
  #-------------------------------------------------------------------
    if ($Apache::Dispatch::DEBUG > 1) {
      $log->info("\tapplying the following dispatch rules:" . 
         "\n\t\tDispatchDeny: " . (join ' ', @{$scfg->{_deny}}) . 
         "\n\t\tDispatchAllow: " . (join ' ', @{$scfg->{_allow}}) .
         "\n\t\tDispatchMethod: " . $scfg->{_method} .
         "\n\t\tDispatchMode: " . $scfg->{_mode});
    }

    $method        = $scfg->{_method};

    #-----------------------------------------------------------------
    # apply the allow and deny rules to the base 
    #-----------------------------------------------------------------
    if ($scfg->{_mode} eq "SAFE") {
      $rc          = _check_deny($base, $log, @{$scfg->{_deny}});
    
      if ($rc) {
        $log->info("\t$base denied by DispatchDeny")
          if $Apache::Dispatch::DEBUG;
        $log->info("Exiting Apache::Dispatch");
        return DECLINED;
      }
      else {
        $rc        = _check_allow($base, $log, @{$scfg->{_allow}});
      }
  
      unless ($rc) {
        $log->info("\t$base not permitted by DispatchAllow")
          if $Apache::Dispatch::DEBUG;
        $log->info("Exiting Apache::Dispatch");
        return DECLINED;
      }
    }
    else {
      # Brave mode
      $rc          = _check_deny($base, $log, @{$scfg->{_deny}});

      if ($rc) {
        $log->info("\t$base denied by DispatchDeny")
          if $Apache::Dispatch::DEBUG;
        $log->info("Exiting Apache::Dispatch");
        return DECLINED;
      }
    }
  }

#---------------------------------------------------------------------
# now, try to determine the correct method to dispatch
#---------------------------------------------------------------------

  if ($method eq "HANDLER") {
    $dispatch      = "$base->handler";
    $coderef       = _check_dispatch($dispatch, $log);
  }        
  elsif ($method eq "PREFIX") {
    ($dispatch = $base) =~ s/(.*)::([^:]+)+/$1\->dispatch_$2/;
    $coderef       = _check_dispatch($dispatch, $log);
  }
  else {
    # Determine method
    ($dispatch = $base) =~ s/(.*)::([^:]+)+/$1\->dispatch_$2/;
    $coderef       = _check_dispatch($dispatch, $log);
    
    unless ($coderef) {
      $dispatch    = "$base->handler";
      $coderef     = _check_dispatch($dispatch, $log);
    }
  }

  unless ($coderef) {
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
  $r->push_handlers(PerlHandler => $coderef);
  
#---------------------------------------------------------------------
# wrap up...
#---------------------------------------------------------------------

  $log->info("Exiting Apache::Dispatch");

  return OK;
}

#---------------------------------------------------------------------
# internal and configuration subroutines
# for internal use only
#---------------------------------------------------------------------

# internal methods

sub _check_dispatch {
  my ($dispatch, $log) = @_;

  $log->info("\tchecking the validity of $dispatch")
     if $Apache::Dispatch::DEBUG > 1;

  my $object       = {};

  my ($class, $method) = split '->', $dispatch;

  bless $object, $class;
  my $coderef      = $object->can($method);

  if ($coderef && $Apache::Dispatch::DEBUG > 1) {
    $log->info("\t$dispatch appears to be a valid method call");
  } elsif ($Apache::Dispatch::DEBUG > 1) {
    $log->info("\t$dispatch is not a valid method call");
  }

  return $coderef;  
}

sub _check_deny {
  my ($dispatch, $log, @deny) = @_;

  my $total             = 0;

  foreach my $match (@deny) {
    $log->info("\tchecking $dispatch against DispatchDeny $match")
      if $Apache::Dispatch::DEBUG > 1;

     $total++ if ($dispatch =~ m/^\Q$match/);
  }

  return $total;
}

sub _check_allow {
  my ($dispatch, $log, @allow) = @_;

  my $total             = 0;

  foreach my $match (@allow) {
    $log->info("\tchecking $dispatch against DispatchAllow $match")
      if $Apache::Dispatch::DEBUG > 1;

     $total++ if ($dispatch =~ m/^\Q$match/);
  }

  return $total;
}

# configuration methods

sub _new {
  return bless {}, shift;
}

sub SERVER_CREATE {
  my $class          = shift;
  my $self           = $class->_new;

  return $self;
}

sub SERVER_MERGE {
  my ($parent, $current) = @_;
  my %new = (%$parent, %$current);

  # merge the default _deny values with whatever is already defined
  my @core           = qw(CORE AUTOLOAD UNIVERSAL SUPER);
  my %union          = ();

  foreach my $key (@core, @{$new{_deny}}) {
    $union{$key}++;
  }
  @{$new{_deny}}  = keys %union;

  # for the others, just define some defaults
  $new{_mode}   ||= "SAFE";
  $new{_method} ||= "HANDLER";

  return bless \%new, ref($parent);
}

sub DIR_CREATE {
  my $class          = shift;
  my $self           = $class->_new;

  return $self;
}

sub DIR_MERGE {
  my ($parent, $current) = @_;
  my %new = (%$parent, %$current);

  $new{_method}   ||= "PREFIX";

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
  if ($arg =~ m/^Safe|Brave$/i) {
    $scfg->{_mode} = uc($arg);
  } else {
    die "Invalid DispatchMode $arg!";
  }
}

sub DispatchMethod ($$$) {
  my ($cfg, $parms, $arg) = @_;
  my $scfg = Apache::ModuleConfig->get($parms->server);
  if ($arg =~ m/^Handler|Prefix|Determine$/i) {
    $scfg->{_method} = uc($arg);
    $cfg->{_method}  = uc($arg);
  } else {
    die "Invalid DispatchMethod $arg!";
  }
}

sub DispatchBase ($$$) {
  my ($cfg, $parms, $arg) = @_;
  
  die "DispatchBase must be defined" unless $arg;
  $cfg->{_base} = $arg;
}

1;

__END__

=head1 NAME

Apache::Dispatch - call PerlHandlers with the ease of CGI scripts

=head1 SYNOPSIS

httpd.conf:

  PerlModule Apache::Dispatch
  PerlFixupHandler Apache::Dispatch

  DispatchMode Safe
  DispatchMethod Handler
  DispatchAllow Custom
  DispatchDeny Apache Protected

  <Location /Foo>
    PerlModule Bar
    DispatchBase Bar
    DispatchMethod Prefix
  </Location>

=head1 DESCRIPTION

Apache::Dispatch translates $r->uri into a class and method and runs
it as a PerlHandler.  Basically, this allows you to call PerlHandlers
as you would CGI scripts - directly from the browser - without having
to load your httpd.conf with a slurry of <Location> tags.

=head1 EXAMPLE

there are two ways of configuring Apache::Dispatch:

per-server:
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

per-location:
  in httpd.conf

    PerlModule Apache::Dispatch
    PerlModule Bar

    <Location /Foo>
      PerlFixupHandler Apache::Dispatch
      DispatchBase Bar
      DispatchMethod Prefix
    </Location>

  in browser:
    http://localhost/Foo/baz

  the results are the same as if your httpd.conf looked like:
    <Location /Foo>
       SetHandler perl-script
       PerlHandler Bar::dispatch_baz
    </Location>

  The per-location configuration offers additional security and
  protection by hiding both the name of the package and method from
  the browser.  Because any class under the Bar:: hierarchy can be
  called, one <Location> directive is be able to handle all the
  methods of Bar, Bar::Baz, etc...


=head1 CONFIGURATION DIRECTIVES

  DispatchBase  
    Applies on a per-location basis only.  The base class to be 
    substituted for the $r->location part of the uri.

  DispatchMethod 
    Applies on a per-server or per directory basis.  Each directory 
    or virtual host will inherit the value of the server if it does
    not specify a method itself.  It accepts the following values:

      Handler   - Assume the method name is handler(), for example
                  /Foo/Bar becomes Foo::Bar->handler().
                  This is the default value outside of <Location>
                  directives configured with DispatchBase.

      Prefix    - Assume the method name is the last part of the 
                  uri and prefix dispatch_ to the method name.
                  /Foo/Bar becomes Foo->dispatch_bar().
                  This is the default value within <Location>
                  directives configured with DispatchBase.

      Determine - The method may either be handler() or the last part
                  of the uri prefixed with dispatch_.  The method 
                  will be determined by first trying dispatch_method()
                  then by trying handler().

  DispatchMode    
    Applies on a per-server basis, except where a <Location> directive
    is using DispatchBase.  Values of the main server will be inherited
    by each virtual host.  It accepts the following values:

        Safe    - Allow only those methods whose namespace is 
                  explicitly allowed by DispatchAllow and explicitly
                  not denied by DispatchDeny.  This is the default.

        Brave   - Allow only those methods whose namespace is 
                  explicitly not denied by DispatchAllow.  This is
                  primarily intended for development and ought to
                  work quite nicely with Apache::StatINC.  Its 
                  security is not guaranteed.
                  
  DispatchAllow 
    A list of namespaces allowed to be dispatched according to the 
    above DispatchMethod and DispatchMode rules.  Applies on a 
    per-server basis, except where a <Location> directive is using 
    DispatchBase.  Values of the main server will be inherited by each
    virtual host. 

  DispatchDeny
    A list of namespaces denied dispatch according to the above
    DispatchMethod and DispatchMode rules.  Applies on a per-server
    basis, except where a <Location> directive is using DispatchBase.
    Values of the main server will be inherited by each virtual host.

=head1 NOTES

There is no require()ing or use()ing of the packages or methods prior
to their use as a PerlHandler.  This means that if you try to dispatch
a method without a PerlModule directive or use() entry in your 
startup.pl you probably will not meet with much success.  This adds a
bit of security and reminds us we should be pre-loading that code in
the parent process anyway...

Apache::Dispatch tries to be a bit intelligent about things.  If, by
the time it reaches the fixup phase, the uri can be mapped to a real
file, directory, or <Location> tag (other than one containing a
DispatchBase directive), Apache::Dispatch declines to handle the
request.

If the uri can be dispatched but contains anything other than
[a-zA-Z0-9_/-] Apache::Dispatch declines to handle the request.

DispatchDeny always includes the following namespaces:
  AUTOLOAD
  CORE
  SUPER
  UNIVERSAL

Like everything in perl, the package names are case sensitive.

Verbose debugging is enabled by setting $Apache::Dispatch::DEBUG=1.
Very verbose debugging is enabled at 2.  To turn off all debug
information set your apache LogLevel directive above info level.

This is alpha software, and as such has not been tested on multiple
platforms or environments for security, stability or other concerns.
It requires PERL_FIXUP=1, PERL_LOG_API=1, PERL_HANDLER=1, and maybe
other hooks to function properly.

=head1 FEATURES/BUGS

No known bugs or features at this time...

=head1 SEE ALSO

perl(1), mod_perl(1), Apache(3)

=head1 AUTHOR

Geoffrey Young <geoff@cpan.org>

=head1 COPYRIGHT

Copyright 2000 Geoffrey Young - all rights reserved.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
