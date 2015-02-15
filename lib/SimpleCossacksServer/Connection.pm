package SimpleCossacksServer::Connection;
use Mouse;
extends 'GSC::Server::Connection';
my $MAXID = 1;
has id => (is => 'ro', default => sub { $MAXID++ });
has ctime => (is => 'ro', default => sub { time });

sub log_message {
  my($self) = @_;
  my $message = $self->id . " " . $self->ip . " ";
  my $cd = $self->data;
  if($cd->{id} || $cd->{nick}) {
    $message .= "$cd->{nick}:";
    $message .= $cd->{id} - 0x7FFFFFFF + 1 if $cd->{id};
  } else {
    $message .= "."
  }
  return $message;
}

__PACKAGE__->meta->make_immutable();
