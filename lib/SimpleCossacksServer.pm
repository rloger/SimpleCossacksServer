package SimpleCossacksServer;
our $VERSION = '0.01';
use Mouse;
use SimpleCossacksServer::CommandController;
use SimpleCossacksServer::ConnectionController;
use SimpleCossacksServer::Handler;
use SimpleCossacksServer::Connection;
use Template;
use Config::Simple;
use POSIX();
extends 'GSC::Server';
has template_engine => (is => 'rw');
has config_file => (is => 'ro');
has connection_controller => (is => 'ro', default => sub { SimpleCossacksServer::ConnectionController->new() });
has log_level => (is => 'rw');
has config => (is => 'rw', builder => '_build_config');
has host => (is => 'ro', default => sub { shift->config->{host} // 'localhost' });
has port => (is => 'ro', default => sub { shift->config->{port} // 34001 });
has log_access_ctx => (is => 'rw', builder => '_build_log_access_ctx');
has log_error_ctx => (is => 'rw', builder => '_build_log_error_ctx');

sub command_controller { 'SimpleCossacksServer::CommandController' }
sub handler_class { 'SimpleCossacksServer::Handler' }
sub connection_class { 'SimpleCossacksServer::Connection' }

sub init {
  my($self) = @_;

  $self->data->{ids} = [];
  $self->data->{dbtbl} = {};
  $self->data->{rooms_by_ctlsum} = {};
  $self->data->{rooms_by_player} = {};
  $self->template_engine( Template->new(
    INCLUDE_PATH => $self->config->{templates},
    CACHE_SIZE   => 64,
    START_TAG    => '<\?',
    END_TAG      => '\?>',
    PLUGINS => {
        CMDFilter => 'SimpleCossacksServer::Template::Plugin::CMDFilter',
    },
  ) );

  # AnyEvent::Log
  $AnyEvent::Log::LOG->log_cb(sub { print STDERR shift; 0 });
}

sub _build_log_error_ctx {
  my($self) = @_;
  if($self->config->{error_log}) {
    my $errorCtx = AnyEvent::Log::Ctx->new(
      level => "warn",
      log_to_file => $self->config->{error_log},
    );
    $AnyEvent::Log::COLLECT->attach($errorCtx);
    return $errorCtx;
  } else {
    return undef;
  }
}

sub _build_log_access_ctx {
  my($self) = @_;
  my $ctx = AnyEvent::Log::ctx($self->meta->name);
  if($self->config->{access_log}) {
    my $infoCtx = AnyEvent::Log::Ctx->new(
      levels => "info",
      log_to_file => $self->config->{access_log},
    );
    $infoCtx->fmt_cb(sub {
      my($time, $ctx, $level, $message) = @_;
      return "[" . POSIX::strftime("%Y-%m-%d/%H:%M:%S", localtime $time) . sprintf(".%03d", ($time - int $time)*1000 ) . "] " . $message . "\n";
    });
    $ctx->attach($infoCtx);
    return $infoCtx;
  } else {
    return undef;
  }
}

sub start {
  my $self = shift;
  local $ENV{TZ} = 'UTC';
  $self->data->{start_at} = POSIX::strftime "%Y-%m-%d %H:%M %Z", localtime time;
  $self->SUPER::start(@_);
}

sub reload {
  my $self = shift;
  $self->log->notice('reset server');

  $self->reload_config;

  if($self->config->{access_log}) {
    if($self->log_access_ctx) {
      $self->log_access_ctx->log_to_file( $self->config->{access_log} );
    } else {
      $self->log_access_ctx( $self->_build_log_access_ctx );
    }
  } else {
    if($self->log_access_ctx) {
      AnyEvent::Log::ctx($self->meta->name)->detach($self->log_access_ctx);
      $self->log_access_ctx(undef);
    }
  }

  if($self->config->{error_log}) {
    if($self->log_error_ctx) {
      $self->log_error_ctx->log_to_file( $self->config->{error_log} );
    } else {
      $self->log_error_ctx( $self->_build_log_error_ctx );
    }
  } else {
    if($self->log_error_ctx) {
      $AnyEvent::Log::COLLECT->detach($self->log_error_ctx);
      $self->log_error_ctx(undef);
    }
  }
}

sub _build_config {
  my($self) = @_;
  my $config = {};
  my $cfg = Config::Simple->new($self->config_file) or die Config::Simple->error();
  $config = $cfg->vars();
  for my $key (keys %$config) {
    $config->{$1} = delete $config->{$key} if $key =~ /^default\.(.*)/;
  }
  $config->{table_timeout} //= 10000;
  return $config;
}

sub reload_config {
  my($self) = @_;
  my $config = {};
  my $cfg = Config::Simple->new($self->config_file) or $self->log->error( Config::Simple->error() );
  $config = $cfg->vars();
  for my $key (keys %$config) {
    $config->{$1} = delete $config->{$key} if $key =~ /^default\.(.*)/;
  }
  @$config{'port', 'host'} = @{$self->config}{'host', 'port'};
  $config->{table_timeout} //= 10000;
  $self->config($config);
}

sub _room_control_sum {
  my($self, $row) = @_;
  $row = join "", @$row if ref($row) eq 'ARRAY';
  my $V1 = 1;
  my $V2 = 0;
  for(my $i = 0; $i < (length($row) + 5552 - 1); $i += 5552) {
    for(my $j = $i; $j < ($i + 5552) and $j < length($row); $j++) {
      my $c = ord(substr($row, $j, 1));
      $V1 += $c;
      $V2 += $V1;
    }
    $V1 %= 0xFFF1;
    $V2 %= 0xFFF1;
  }
  my $r = ($V2 << 0x10) | $V1;
  return $r;
}

sub leave_room {
  my($self, $player_id) = @_;
  my $room = $self->data->{rooms_by_player}{$player_id} or return;
  
  delete $self->data->{rooms_by_player}{ $player_id };
  delete $room->{players}{ $player_id };
  $room->{players_count}--;
  $room->{row}[-3] = $room->{players_count} . "/" . $room->{max_players};

  if($room->{started} ? $room->{players_count} <= 0 : $room->{host_id} == $player_id) {
    # в случае $room->{started} очистка лишняя, но на всякий случай оставим
    delete $self->data->{rooms_by_ctlsum}{ $room->{ctlsum} };
    delete $self->data->{rooms_by_id}{ $room->{id} };
    my $rooms_list = $self->data->{dbtbl}{ "ROOMS_V" . $room->{ver} };
    for(my $i = 0; $i < @$rooms_list; $i++) {
      if($rooms_list->[$i]{id} == $room->{id}) {
        splice @$rooms_list, $i, 1;
        last;
      } 
    }
  }
  return $room;
}

sub start_room {
  my($self, $player_id) = @_;
  my $room = $self->data->{rooms_by_player}{$player_id} or return;
  
  if($room->{host_id} == $player_id) {
    delete $self->data->{rooms_by_ctlsum}{ $room->{ctlsum} };
    delete $self->data->{rooms_by_id}{ $room->{id} };
    $room->{started} = 1;
    my $rooms_list = $self->data->{dbtbl}{ "ROOMS_V" . $room->{ver} };
    for(my $i = 0; $i < @$rooms_list; $i++) {
      if($rooms_list->[$i]{id} == $room->{id}) {
        splice @$rooms_list, $i, 1;
        last;
      } 
    }
  }
  return $room;
}

__PACKAGE__->meta->make_immutable();

=head1 NAME

SimpleCossacksServer - простой сервер для игры в Казаки и ЗА
