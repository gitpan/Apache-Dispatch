package Apache::Dispatch;

#---------------------------------------------------------------------
#
# usage: PerlHandler Apache::Dispatch
#        
#---------------------------------------------------------------------

use Apache::Constants qw( OK DECLINED SERVER_ERROR);
use Apache::Log;
use Apache::ModuleConfig;
use DynaLoader ();
use strict;

$Apache::Dispatch::VERSION = '0.03';

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
  
  my ($prehandler, $posthandler, $errorhandler, $rc) = undef;

#---------------------------------------------------------------------
# do some preliminary stuff...
#---------------------------------------------------------------------
  
  $log->info("Using Apache::Dispatch");

  $log->info("\tchecking $uri for possible dispatch...")
     if $Apache::Dispatch::DEBUG;

  # if the uri contains any characters we don't like, bounce
  if ($uri =~ m![^\w/-]!) {
    $log->info("\t$uri has bogus characters...")
       if $Apache::Dispatch::DEBUG;
    $log->info("Exiting Apache::Dispatch");
    return DECLINED;
  }

  my $dcfg         = Apache::ModuleConfig->get($r);
  my $scfg         = Apache::ModuleConfig->get($r->server);

  unless ($dcfg->{_prefix}) {
    $log->error("\tDispatchPrefix is not defined!");
    $log->info("Exiting Apache::Dispatch");
    return DECLINED;
  }

  if ($Apache::Dispatch::DEBUG > 1) {
    $log->info("\tapplying the following dispatch rules:" . 
       "\n\t\tDispatchPrefix: " . $dcfg->{_prefix} .
       "\n\t\tDispatchExtras: " . 
         ($dcfg->{_extras} ? (join ' ', @{$dcfg->{_extras}}) : 
         ($scfg->{_extras} ? (join ' ', @{$scfg->{_extras}}) : "None"))
    );
  } 

#---------------------------------------------------------------------
# create the new object
#---------------------------------------------------------------------
  
  my ($class, $method) = _translate_uri($r, $dcfg->{_prefix});
  
  my $object       = {};

  bless $object, $class;

#---------------------------------------------------------------------
# see if the handler is a valid method
# if not, decline the request
#---------------------------------------------------------------------
  
  my $handler = _check_dispatch($object, $method, $log);

  if ($handler) {
    $log->info("\t$uri was translated into $class->$method")
       if $Apache::Dispatch::DEBUG;
  }
  else {
    $log->info("\t$uri did not result in a valid method")
      if $Apache::Dispatch::DEBUG;
    $log->info("Exiting Apache::Dispatch");
    return DECLINED;
  }

#---------------------------------------------------------------------
# since the uri is dispatchable, check each of the extras
#---------------------------------------------------------------------

  my @extras  = $dcfg->{_extras} ? 
                  @{$dcfg->{_extras}} : 
                  @{$scfg->{_extras}};

  foreach my $extra (@extras) {
    if ($extra eq "PRE") {
      $prehandler = _check_dispatch($object, "pre_dispatch", $log);
    }
    elsif ($extra eq "POST") {
      $posthandler = _check_dispatch($object, "post_dispatch", $log);
    }
    elsif ($extra eq "ERROR") {
      $errorhandler 
        = _check_dispatch($object, "error_dispatch", $log);
    }
  }
  
#---------------------------------------------------------------------
# run each of the enabled methods, ignoring pre and post errors
#---------------------------------------------------------------------
  
  eval { $object->$prehandler($r) } if $prehandler;

  eval { $rc = $object->$handler($r) };

  if ($errorhandler && ($@ || $rc != OK)) {
    $rc = $object->$errorhandler($r);
  } 
  elsif ($@) {
    $rc = SERVER_ERROR;
  }

  eval { $object->$posthandler($r) } if $posthandler;

#---------------------------------------------------------------------
# wrap up...
#---------------------------------------------------------------------

  $log->info("Exiting Apache::Dispatch");

  return $rc;
}


#*********************************************************************
# the below methods are not part of the external API
#*********************************************************************

sub _translate_uri {
#---------------------------------------------------------------------
# take the uri and return a class and method
# this method is for internal use only
#---------------------------------------------------------------------

  my ($r, $prefix)   = @_;

  # change all the / to :: 
  (my $class_and_method = $r->uri) =~ s!/!::!g;

  # strip off the leading and trailing :: if any
  $class_and_method  =~ s/^::|::$//g;

  # substitute the prefix for the location
  (my $location = $r->location) =~ s!/!!;
  $class_and_method  =~ s/^$location/$prefix/e;

  # change that last :: to a ->
  $class_and_method  =~ s/(.*)::([^:]+)+/$1\->dispatch_$2/;

  my ($class, $method) = split /->/, $class_and_method;

  # make a call to / default to dispatch_index
  $method = "dispatch_index" unless $method;

  return ($class, $method);
}

sub _check_dispatch {
#---------------------------------------------------------------------
# see if class->method() is a valid call
# this method is for internal use only
#---------------------------------------------------------------------

  my ($object, $method, $log) = @_;

  my $class = ref($object);

  $log->info("\tchecking the validity of $class->$method...")
     if $Apache::Dispatch::DEBUG > 1;

  my $coderef      = $object->can($method);

  if ($coderef && $Apache::Dispatch::DEBUG > 1) {
    $log->info("\t$class->$method is a valid method call");
  } elsif ($Apache::Dispatch::DEBUG > 1) {
    $log->info("\t$class->$method is not a valid method call");
  }

  return $coderef;  
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

  return bless \%new, ref($parent);
}

sub DispatchPrefix ($$$) {
  my ($cfg, $parms, $arg) = @_;
  
  die "DispatchPrefix must be defined" unless $arg;
  $cfg->{_prefix} = $arg;
}

sub DispatchExtras ($$@) {
  my ($cfg, $parms, $arg) = @_;
  my $scfg = Apache::ModuleConfig->get($parms->server);
  
  if ($arg =~ m/^Pre|Post|Error$/i) {
    push @{$scfg->{_extras}}, uc($arg);
    push @{$cfg->{_extras}}, uc($arg);
  } 
  else {
    die "Invalid DispatchExtra $arg!";
  }
}

1;

__END__

=head1 NAME

Apache::Dispatch - call PerlHandlers with the ease of CGI scripts

=head1 SYNOPSIS

httpd.conf:

  PerlModule Apache::Dispatch
  PerlModule Bar

  <Location /Foo>
    SetHandler perl-script
    PerlHandler Apache::Dispatch

    DispatchPrefix Bar
    DispatchExtras Pre Post Error
  </Location>

=head1 DESCRIPTION

Apache::Dispatch translates $r->uri into a class and method and runs
it as a PerlHandler.  Basically, this allows you to call PerlHandlers
as you would CGI scripts - directly from the browser - without having
to load your httpd.conf with a slurry of <Location> tags.

=head1 EXAMPLE

  in httpd.conf

    PerlModule Apache::Dispatch
    PerlModule Bar

    <Location /Foo>
      SetHandler perl-script
      PerlHandler Apache::Dispatch

      DispatchPrefix Bar
    </Location>

  in browser:
    http://localhost/Foo/baz

the results are the same as if your httpd.conf looked like:
    <Location /Foo>
       SetHandler perl-script
       PerlHandler Bar::dispatch_baz
    </Location>

but with the additional security of protecting the class name from
the browser and keeping the method name from being called directly.
Because any class under the Bar:: hierarchy can be called, one
<Location> directive is be able to handle all the methods of Bar,
Bar::Baz, etc...

=head1 CONFIGURATION DIRECTIVES

  DispatchPrefix
    The base class to be substituted for the $r->location part of the
    uri.  Applies on a per-location basis only.  

  DispatchExtras
    A list of extra processing to enable per-request.  They may be
    applied on a per-server or per-location basis.  If the main
    handler is not a valid method call, the request is declined prior
    to the execution of any of the extra methods.

      Pre   - eval()s Foo->pre_dispatch() prior to dispatching the uri
              uri.  The $@ of the eval is not checked in any way.

      Post  - eval()s Foo->post_dispatch() prior to dispatching the
              uri.  The $@ of the eval is not checked.

      Error - If the main handler returns other than OK then 
              Foo->error_dispatch() is called and return status of it
              is returned instead.  Without this feature, the return
              status of your handler is returned.

=head1 SPECIAL CODING GUIDELINES

Apache::Dispatch uses object oriented calls behind the scenes.  This 
means that you either need to account for your handler to be called
as a method handler, such as

  sub dispatch_bar {
    my $class = shift;  # your class
    my $r = shift;
  }

or get the Apache request object yourself via

  sub dispatch_bar {
    my $r = Apache->request;
  }

This also has the interesting side effect which would allow you to
define, say, a base error_dispatch() method in Foo which is then
inherited by Foo::Bar, but overriden in Foo::Bar::Baz.

=head1 NOTES

In addition to the special methods pre_dispatch(), post_dispatch(),
and error_dispatch(), if you define dispatch_index() it will be called
by /Foo or /Foo/.  /Foo/index is always directly callable, but /Foo 
will only translate to /Foo/index at the highest level - that is,
when just the location is specified.  Meaning /Foo/Baz/index will call
Bar::Baz->dispatch_index, but /Foo/Baz will try to call Bar->Baz().

There is no require()ing or use()ing of the packages or methods prior
to their use as a PerlHandler.  This means that if you try to dispatch
a method without a PerlModule directive or use() entry in your 
startup.pl you probably will not meet with much success.  This adds a
bit of security and reminds us we should be pre-loading that code in
the parent process anyway...

If the uri can be dispatched but contains anything other than
[a-zA-Z0-9_/-] Apache::Dispatch declines to handle the request.

Like everything in perl, the package names are case sensitive.

Verbose debugging is enabled by setting $Apache::Dispatch::DEBUG=1.
Very verbose debugging is enabled at 2.  To turn off all debug
information set your apache LogLevel directive above info level.

This is alpha software, and as such has not been tested on multiple
platforms or environments for security, stability or other concerns.
It requires PERL_DIRECTIVE_HANDLERS=1, PERL_METHOD_HANDLERS=1,
PERL_LOG_API=1, PERL_HANDLER=1, and maybe other hooks to function 
properly.

=head1 FEATURES/BUGS

No known bugs or unexpected features at this time...

=head1 SEE ALSO

perl(1), mod_perl(1), Apache(3)

=head1 AUTHOR

Geoffrey Young <geoff@cpan.org>

=head1 COPYRIGHT

Copyright 2000 Geoffrey Young - all rights reserved.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
