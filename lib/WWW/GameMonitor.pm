package WWW::GameMonitor;

our $VERSION = '0.01';

use XML::Simple;
use Data::Dumper;
use LWP::Simple;
use Hey::Common;

=cut

=head1 NAME

WWW::GameMonitor - Fetch information about game servers from Game-Monitor.com

=head1 SYNOPSIS

  # example 1
  use WWW::GameMonitor;
  my $gm1 = WWW::GameMonitor->new;
  my $serv1 = $gm->getServerInfo( Host => '216.237.126.132', Port => '16567' ); # ACE Battlefield2 Server
  print qq(On $serv1->{name}, $serv1->{count}->{current} players ($serv1->{count}->{max} limit) are playing $serv1->{game}->{longname}, map $serv1->{map}.\n);
  
  # example 2
  use WWW::GameMonitor;
  my $gm2 = WWW::GameMonitor->new( Host => '216.237.126.132', Port => '16567' ); # default to a certain server
  my $serv2 = $gm->getServerInfo; # uses the defaults specified in the constructor

=head1 DESCRIPTION

This module will help you get information about various official and clan game servers (Battlefield 2, Quake 4, and many more).  The server 
that is being queried must be listed as a "premium" server.  This means someone (you, the server owner, or someone else) must have an active 
subscription with Game-Monitor.com for that server to be accessible in this way.  You, yourself, do not have to have an account with them, but 
someone out there on the Internet must have listed that specific server in their paid account.  For example, at the time of writing, the ACE 
Battlefield 2 server E<lt>http://www.armchairextremist.com/E<gt> is listed under such an account.  This means that you could, without needing 
to contact or pay anyone, use this module to ask for information about the ACE Battlefield 2 server.  If you run your own clan game server 
(and Game-Monitor.com supports your game), it might be worth it to you to pay them the ~USD$3-7/month for this ability.  They take PayPal.

=head2 new

  my $gm = WWW::GameMonitor->new; # no options or defaults specified
  
  my $gm = WWW::GameMonitor->new( Host => '216.237.126.132', Port => '16567' ); # default to a certain server

You can specify several options in the constructor.

  my $gm = WWW::GameMonitor->new(
      Fresh => 300,
      Host => '216.237.126.132',
      Port => '16567',
      StoreFile => 'my_gm_cache.xml',
      DebugLog => 'my_debug_log.txt',
      DebugLevel => 3,
  );

=head3 Fresh [optional]

Sets the data store (cache) freshness in seconds.  If the store has data older than this number of seconds, it is no longer valid.  It's best 
that you set this value to something higher than 1 minute and would be even better if you were satisfied with setting it around 5 minutes.  If 
the store is fresh enough, it won't even ask the Game-Monitor.com server for any information.  Keep in mind that Game-Monitor doesn't update 
their information more than once every several minutes.  It won't be useful for you to set the Fresh number too low.

=head3 Host [optional]

Sets the default host to ask about.  If you don't specify a host when asking for data, it will use this value instead.

=head3 Port [optional]

Sets the default port to ask about.  If you don't specify a port when asking for data, it will use this value instead.

=head3 StoreFile [optional]

Sets the path and filename for the data store (cache).  This is "gameServerInfoCache.xml" by default.

=head3 DebugLog [optional]

Sets the path and filename for the debug log.  This is "gmDebug.log" by default.  To enable logging, you'll have to choose a DebugLevel 
greater than zero (zero is default).

=head3 DebugLevel [optional]

Sets the level of debugging.  The larger the number, the more verbose the logging.  This is zero by default, which means no logging at all.

=cut

sub new {
  my $class = shift;
  my %options = @_;
  my $self = {};
  bless($self, $class); # class-ify it.

  $self->{fxn} = Hey::Common->new;

  $self->{debugLog} = $options{DebugLog} || 'gmDebug.log';
  $self->{debugLevel} = $options{DebugLevel} || 0;
  $self->{storeFile} = $options{StoreFile} || 'gameServerInfoCache.xml';

  $self->{storeFresh} = $options{Fresh} || 600; # how many seconds do we consider the store to be fresh?

  eval { $self->{store} = XMLin($self->{storeFile}); }; # read in store XML data (it's okay if it fails/doesn't exist, I think)

  $self->{host} = $options{Host} || undef;
  $self->{port} = $options{Port} || undef;

  $self->__debug(7, 'Object Attributes:', Dumper($self));

  return $self;
}

sub __debug {
  my $self = shift || return undef;
  return undef unless $self->{debugLog}; # skip unless log file is defined
  my $level = int(shift);
  return undef unless $self->{debugLevel} >= $level; # skip unless log level is as high as this item
  if (open(GAMEMONDEBUG, ">>$self->{debugLog}")) {
    my $time = localtime();
    foreach my $group (@_) { # roll through many items if they are passed in as an array
      foreach my $line (split(/\r?\n/, $group)) { # roll through items that are multiline, converting to multiple separate lines
        print GAMEMONDEBUG "[$time] $line\n";
      }
    }
    close(GAMEMONDEBUG);
  }
  return undef;
}

sub __injectIntoDataStore {
  my $self = shift;
  my $data = shift;

  (my $name = "ip_$data->{ip}_$data->{port}") =~ s|\.|_|g; # make an XML friendly key
  $self->{store}->{$name} = $data; # insert the data into the store

  my $storeOut = XMLout($self->{store}); # convert hashref data into XML structure
  if ($storeOut) { # only if storeOut is valid/existing (wouldn't want to wipe out our only cache/store with null)
    if (open(STOREFH, '>'.$self->{storeFile})) { # overwrite old store file with new store file
      print STOREFH $storeOut;
      close(STOREFH);
    }
  }

  return undef;
}

sub __fetchServerInfo {
  my $self = shift || return undef;
  my %options = @_;
  my $host = $options{Host} || return undef; # if the host isn't defined, fail
  my $port = $options{Port} || return undef; # if the port isn't defined, fail

  (my $name = "ip_${host}_${port}") =~ s|\.|_|g; # make an XML friendly key

  my $store = $self->{store}->{$name}; # get data from store
  if ($store) { # store data exists for this host/port
    if ($VERSION eq $store->{client_version} ## check the client version against the cache, in case the client (this code) has been upgraded, which might break the cache
     && $store->{updated} + $self->{storeFresh} > time()) { # if it's valid and still fresh, use it instead
      $self->__debug(3, 'Store data is fresh.  Returning store data.');
      return $store;
    }
    $self->__debug(2, 'Store is not fresh enough.  Fetching from source.');
  }
  else {
    $self->__debug(3, 'There is no store data for this host/ip.  Fetching from source.');
  }

  my $url = qq(http://www.game-monitor.com/client/server-xml.php?rules=1&ip=$host:$port); # format the url for the source
  my $response = get($url); # fetch the info from the source
  unless ($response) { # it failed (rejected, bad connection, etc)
    $self->__debug(2, 'Could not fetch data from source.');
    if ($store) {
      $self->__debug(2, 'Going to provide stale store data instead of failing.');
      return $store;
    }
    else { # there is nothing to send back, fail
      $self->__debug(3, 'There is no store data to return.');
      return undef;
    }
  }
  my $data = XMLin($response, KeyAttr => undef); # parse the xml into hashref
  $data->{count} = $data->{players}; # move the player counts
  $data->{players} = $self->{fxn}->forceArray($data->{players}->{player}); # make sure players is an arrayref
  delete($data->{count}->{player}); # cleanup unnecessary stuff
  my $variables = $self->{fxn}->forceArray($data->{variables}->{variable}); # make sure variables is an arrayref
  delete($data->{variables}); # remove the messy looking and difficult to use variables structure

  foreach my $variable (@{$variables}) { # loop through the messy variables
    $data->{variables}->{$variable->{name}} = $variable->{value}; # make them pretty and easy to use
  }

  $data->{updated} = time(); # set the updated timestamp
  $data->{client_version} = $VERSION;

  $self->__injectIntoDataStore($data); # store it, baby!

  return $data;
}

=cut

=head2 getServerInfo

  my $serv = $gm->getServerInfo; # uses the defaults specified in the constructor
  print qq(On $serv1->{name}, $serv1->{count}->{current} players ($serv1->{count}->{max} limit) are playing $serv1->{game}->{longname}, map $serv1->{map}.\n);
  
  my $serv = $gm->getServerInfo( Host => '216.237.126.132', Port => '16567' ); # ask about a certain server
  print qq(On $serv1->{name}, $serv1->{count}->{current} players ($serv1->{count}->{max} limit) are playing $serv1->{game}->{longname}, map $serv1->{map}.\n);

=head3 Host [required]

Asks about the specified host.  If this was specified in the constructor, this value is optional.

=head3 Port [required]

Asks about the specified port.  If this was specified in the constructor, this value is optional.

=cut

sub getServerInfo {
  my $self = shift || return undef;
  my %options = @_;
  my $host = $options{Host} || $self->{host} || return undef; # if the host isn't defined, get the default or fail
  my $port = $options{Port} || $self->{port} || return undef; # if the port isn't defined, get the default or fail
  my $data = $self->__fetchServerInfo( Host => $host, Port => $port ); # fetch it!
  return $data; # return the post-processed server info
}

=cut

=head1 AUTHOR

Dusty Wilson, E<lt>www-gamemonitor-module@dusty.hey.nuE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2006 by Dusty Wilson E<lt>http://dusty.hey.nu/E<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

1;
