use strict;
use warnings;
use Test::More tests=>14;
use Data::Dumper;
use Type::Hints qw(has class private lazy def);
use experimental 'signatures';

class Foo {
    has bar;
    has baz : Data::Dumper;
    has qux = 3;
    has quux : int = 5;
    has thud : str = "A thud";
    private privateVar = 2;

    has zsubAttr = sub {
        my $self = shift;
        return $self->qux;
    };

    lazy zzAttr = sub {
        my $self = shift;
        return $self->qux;
    };

    sub _init ($self, $args) {
        $self->quux += $args->{'bar'};
    }

    def fetch_private ($self) : int {
        return $self->privateVar;
    }
}

my $foo = Foo(bar=>2, baz=>Data::Dumper->new([], []), thud=>'Overridden');

is($foo->bar, 2, 'Simple assignment');

is(ref($foo->baz), "Data::Dumper", 'Class type hint');

is($foo->{"qux"}, 3, 'Defaults by hash');

is($foo->qux, 3, 'Defaults');
$foo->qux = 5;

is($foo->zsubAttr, 3, 'Eager defaults');

is($foo->zzAttr, 5, 'Lazy defaults');

is($foo->quux, 7, 'Defaults with hints, and a _init function');
$foo->quux = 8;
is($foo->quux, 8, 'L value');
is($foo->thud, 'Overridden', 'Defaults that are overridden');



$foo->{"quux"} = 11;
is($foo->quux, 11, 'Hash assignments');

eval { $foo->privateVar = 3;  };
like($@, qr(privateVar is a private attribute), 'Private attributes in dataclass');

is($foo->fetch_private, 2, 'Private allows internal access');

is($foo->{"_privateVar"}, 2, 'Mangled named for private');
is($foo->{"privateVar"}, undef, 'Mangled named for private 2');