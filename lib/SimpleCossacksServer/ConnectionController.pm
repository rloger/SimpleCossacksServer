package SimpleCossacksServer::ConnectionController;
use Mouse;
extends 'GSC::Server::ConnectionController';

sub _connect {
  my($self, $h) = @_;
  $h->log->info($h->connection->log_message . ' #connect');
}

sub _close {
  my($self, $h) = @_;
  my $ids = $h->server->data->{ids};
  if(my $id = $h->connection->data->{id}) {
    for(my $i = 0; $i < @$ids; $i++) {
      if($ids->[$i] == $id) {
        splice @$ids, $i, 1;
        last;
      }
    }
    delete $h->server->data->{nicks}{$id};
  }
  $h->log->info($h->connection->log_message . ' #disconnect');
}
  
__PACKAGE__->meta->make_immutable();
