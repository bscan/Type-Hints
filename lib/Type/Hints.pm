package Type::Hints;
use v5.20;
use strict;
#use warnings;
use Keyword::Simple ();
use Carp qw( croak );
use feature ();
use Text::Balanced  qw( extract_bracketed );
use Sentinel ();

our $VERSION = "0.01";

# Currently only supporting array based containers
my $containers = {
    "int" => 0,
    "str" => 0,
    "bool" => 0,
    "undef" => 0,
    "num"  => 0,
    "scalar" => 0,
    "array" => 1,
    "hash" => 0,
    "coderef" => 0,
    "object" => 1,
    "hashref" => 0,
    "arrayref" => 1,
    "scalarref" => 0,
};

my $keywords = {
    'def'       => 1,
    'let'       => 1,
    'class'     => 1,
    'has'       => 1,
    'public'    => 1,
    'private'   => 1,
    'protected' => 1,
    'readonly'  => 1,
    'initvar'   => 1,
    'lazy'      => 1
};

# This will intentionally reference by partial name, so multiple Person class can collide
my $class_shortname = {};
my $class_longname = {};

my $defaults = {};
my $lazy = {};
my $names = {};

my $HINTS_RG = qr/(?:[:~] # Allow : or ~ to start the hint
                  ( \s*\{[\s\|\w:\[\],]+\} # First alternative is inline object hints like {foo: int, bar: str}
                    |
                    [\s\|\w:\[\]]+   # Second alternative are standard hints (no commas or {} allowed). spaces, or's |, : for Class::Splits, and [] for arrayref[]
                  )
                )/x; 


sub import {
    my $module = shift;
    my @requested = @_;
    my ($def, $let);

    my $exported = {};

    if(!@requested){
        # Export everything is they didn't specify
        $exported = $keywords;
    }

    foreach my $request (@requested){
        croak "$request is not available in the TypeHints module" if ( !defined($containers->{$request}) and !defined($keywords>{$request})) ;
        $exported->{$request} = 1;
    }

    if($exported->{'def'}) {
        feature->import('signatures'); # subroutine signatures
        warnings->unimport('experimental::signatures');
        Keyword::Simple::define 'def', \&build_def;
    }

    if($exported->{'let'}){
        Keyword::Simple::define 'let', \&build_let;
    }

    if($exported->{'class'}){
        my ($caller_pkg, $filename, $line) = caller();
        Keyword::Simple::define 'class', sub {
            my $caller = $caller_pkg;
            build_dataclass($caller, 'class', @_);
        };
    }


    if($exported->{'private'}){
        my ($has_pkg, undef) = caller();
        Keyword::Simple::define 'private', sub {
            my $has = $has_pkg;
            build_has($has, 'private', @_);
        };
    }

    if($exported->{'protected'}){
        my ($has_pkg, undef) = caller();
        Keyword::Simple::define 'protected', sub {
            my $has = $has_pkg;
            build_has($has, 'protected', @_);
        };
    }

    if($exported->{'public'}){
        my ($has_pkg, undef) = caller();
        Keyword::Simple::define 'public', sub {
            my $has = $has_pkg;
            build_has($has, 'public', @_);
        };
    }

    if($exported->{'readonly'}){
        my ($has_pkg, undef) = caller();
        Keyword::Simple::define 'readonly', sub {
            my $has = $has_pkg;
            build_has($has, 'readonly', @_);
        };
    }

    if($exported->{'has'}){
        # Has will conflict with Moo/Moose. For convenience, don't export it if has exists
        my ($has_pkg, undef) = caller();
        my $hasPath = "${has_pkg}::has";
        if( !exists &{$hasPath}) {
            Keyword::Simple::define 'has', sub {
                my $has = $has_pkg;
                build_has($has, 'has', @_);
            };
        }
    }

    if($exported->{'initvar'}){
        my ($has_pkg, undef) = caller();
        Keyword::Simple::define 'initvar', sub {
            my $has = $has_pkg;
            build_has($has, 'initvar', @_);
        };
    }

    if($exported->{'lazy'}){
        my ($has_pkg, undef) = caller();
        Keyword::Simple::define 'lazy', sub {
            my $has = $has_pkg;
            build_has($has, 'lazy', @_);
        };
    }
}
 
sub build_def {
    my ($ref) = @_;
    my $line_count = $$ref =~ tr/\n//;
    $$ref =~ s/^(\s*\w+\b\s*\()([^\)]*)(\))\s*(?:$HINTS_RG)?/'sub '.$1.parse_def_hints($2).$3.validate_hint($4)/e;
    my $new_count = $$ref =~ tr/\n//;
    my $missing = $line_count - $new_count;
    substr($$ref, 0, 0) = "\n" x $missing;
}

sub parse_def_hints {
    my $def_hints = shift;
    $def_hints =~ s/$HINTS_RG/validate_hint($1)/ge;
    return $def_hints;
}

sub build_let {
    my ($ref) = @_;
    my $line_count = $$ref =~ tr/\n//;
    my $sDeclaration = ( split /[\=\;]/, $$ref )[0];
    my $iLen = length($sDeclaration);
    $sDeclaration =~ s/([\$\@\%]\w+\s*)$HINTS_RG/$1.validate_hint($2)/ge;
    $sDeclaration = "my $sDeclaration";
    substr($$ref, 0, $iLen) = $sDeclaration;
    my $new_count = $$ref =~ tr/\n//;
    my $missing = $line_count - $new_count;
    substr($$ref, 0, 0) = "\n" x $missing;
}

sub validate_hint {
    my $hint = shift;
    return if !defined($hint);

    my @hints = get_hints($hint, 0);

    foreach my $hint (@hints){
        $hint =~ s/\s+//g;
        next if !length($hint);
        next if pack_exists($hint);
        next if defined($containers->{$hint});
        next if $class_shortname->{$hint};
        croak("$hint is not a valid type hint. Do you need to import $hint?");
    }
    return "";
}

sub get_hints {
    my ($hintStr, $depth) = @_;

    my @params = ();
    while (length($hintStr)) {
        if($depth++ > 100){
            # Recursive function. We can get stuck in an infinite loop on malformed hints
            croak "Invalid type hints. Perhaps an invalid character or unclosed bracket?";
        }
        if ($hintStr =~ /^\s*\{([^\}]+)\}(?:\||\Z)/ ) {
            # Find inline object hints such as {foo: int, bar: str }.
            # Note that recursive object hints are not yet allowed
            my $objectHint = $1;
            $hintStr =~ s/^\s*\{\Q$1\E\}\s*\|?\s*//;
            my @hints = map { my $s=$_; $s =~ s/^\s*\w+\s*\:\s*(\S+)/$1/; $s } split(",", $objectHint);
            @hints = map { get_hints($_, $depth) } @hints;
            push @params, @hints;
        } 
        elsif ($hintStr =~ /^([^\[]*?)(?:\||\Z)/ ) {
            # Hint without brackets that extends non-greedy until the next | or end of string. Grab it and remove it from the string.
            push @params, $1;
            $hintStr =~ s/^\Q$1\E\s*\|?\s*//;
        } else {
            # The hint has a [] in it, let's extract the content and recursively parse those hints
            my ($ext, $pre);
            ($ext, $hintStr, $pre) = extract_bracketed($hintStr,'[]','[^\[\]]+');
            if($ext =~ /^\[(.*)\]$/){
                push @params, get_hints($1, $depth);
            }
            $pre =~ s/\s+//g;
            croak "$pre is not an allowed container for other type hints." if (defined($containers->{$pre}) and $containers->{$pre} eq 0);
            push @params, "$pre";
            $hintStr =~ s/^\s*\|\s*//;
        }
    }

    return @params;
}


sub unimport {
    # lexically disable keyword again
    Keyword::Simple::undefine 'def';
    Keyword::Simple::undefine 'let';
    Keyword::Simple::undefine 'class';
    Keyword::Simple::undefine 'has';
}



sub build_has {
    my ($has_pkg, $type, $ref) = @_;

    if($$ref =~ s/^\s*(\w+)\s*(?:$HINTS_RG)?\s*(;|=)/replace_has_equals($1, $2, $3, $type)/e){
        #print $$ref
    } else {
        croak "Invalid syntax for has keyword";
    }
}

sub replace_has_equals {
    my ($param, $hint, $terminator, $type) = @_;
    validate_hint($hint);

    my $private = "";
    my $oParam = $param;
    my $lazy = "";
    if($type eq 'private'){
        $private = " Carp::croak('$param is a private attribute') if !(\$self->isa((caller(0))[0]) and ref(\$self) eq (split(/::([^:]+)\$/, (caller(0))[3]))[0] );";
    } elsif($type eq 'protected'){
        $private = " Carp::croak('$param is a protected attribute') if !(\$self->isa((caller(0))[0]));";
    } elsif($type eq 'lazy'){
        $lazy = " \$Type::Hints::lazy->{''.__PACKAGE__}->{'$param'} = 1; "
    }
    
    $param = "_-$param" if ($type eq 'private' or $type eq 'protected' or $type eq 'readonly');
    
    my $readOnly =  ($type eq 'readonly' or $type eq 'lazy') ? " Carp::croak('$oParam is readonly');" : "";

    my $assignment = "";
    if ($terminator eq '='){
        # Due to autovivification, the //= actually isn't needed. I keep it only to prevent "only used once errors on Type::Hints::defaults"
        $assignment = "; \$Type::Hints::defaults->{''.__PACKAGE__} //= {}; $lazy \$Type::Hints::defaults->{''.__PACKAGE__}->{'$param'} = ";
    } elsif($lazy){
        croak("Cannot set type lazy without an assignment");
    }


    my $lvalue = "
        if(\$self and !\$self->isa('Type::Hints::Dataclass') and !exists(\$self->{\"$param\"}) and exists(\$Type::Hints::defaults->{''.__PACKAGE__}->{'$param'})) {
            \$self->{'$param'} = \$Type::Hints::defaults->{''.__PACKAGE__}->{'$param'}
        }
        no warnings 'uninitialized';
        Sentinel::sentinel get => sub { 
                    $private
                    return \$self->can('get_$oParam') && ((caller(1))[3] !~ /::get_$oParam\$/) ? \$self->get_$oParam : 
                            ref(\$self->{'$param'}) eq 'CODE' ?  &{\$self->{'$param'}}(\$self) : \$self->{'$param'}
                    },
                 set => sub {
                    $private
                    $readOnly
                    return \$self->can('set_$oParam') && ((caller(1))[3] !~ /::[sg]et_$oParam\$/) ? \$self->set_$oParam(\$_[0]) : (\$self->{'$param'} = \$_[0])
                };
    ";
    my $pkg_code = " { no strict 'refs';
                    die('$oParam already defined as an attribute') if defined(\$Type::Hints::names->{''.__PACKAGE__}->{'$oParam'});
                    \$Type::Hints::names->{''.__PACKAGE__}->{'$oParam'} = '$param';
                    \${__PACKAGE__ . '::_PARAMS'}{'$param'}='$hint';
                    }" ;

    $lvalue =~ s/\n/ /g; # Ensure line numbers in errors stay the same
    $pkg_code =~ s/\n/ /g;
    if ($type eq 'initvar'){
        return qq( $pkg_code $assignment );
    }
    return qq( sub $oParam :lvalue { my \$self=shift; $lvalue } ${pkg_code} $assignment );
}


sub build_dataclass {
    my ($caller_pkg, $type, $ref) = @_;

    my ($name, $parent);
    my $pkg_name = "${caller_pkg}::";
    my $func_name = $pkg_name;
    my $short_name;
    if($$ref =~ s/^\s*(\w+)(?:\s+extends\s+((?:\w|::)+))?(?:\s|\{|\z)/package ${pkg_name}_$1/){
        $short_name = $1;
        $pkg_name .= "_$1";    
        $func_name .= $1;
        $class_shortname->{$short_name} = 1;    
        $parent = $2;

    } else {
        croak "Invalid class name"
    }

    no strict 'refs'; ## no critic;

    if (scalar keys %{"${pkg_name}::"}){
        croak("class $pkg_name already defined");
    }

    my $prefix = "class ";

    *{"$func_name"} = sub {
        my %args = (@_);

        my $if = bless {}, $pkg_name;
        
        resolve_ancestors($pkg_name);
        my %ext_to_int = %{$Type::Hints::names->{$pkg_name}};
        my %int_to_ext = reverse %{$Type::Hints::names->{$pkg_name}};
        
        foreach my $int_key (sort keys %{"${pkg_name}::_PARAMS"}){
            if ( !defined($args{$int_to_ext{$int_key}})){
                if(exists($Type::Hints::defaults->{$pkg_name}->{$int_key})){
                    $if->{$int_key} = $Type::Hints::defaults->{$pkg_name}->{$int_key};
                } 
            }
        }


        foreach my $ext_key (sort keys %args){
            croak "$ext_key is not a valid argument for class $short_name\n" if !defined(${"${pkg_name}::_PARAMS"}{$ext_to_int{$ext_key}});
            if($if->can("set_$ext_key")){
                my $method = "set_$ext_key";
                $if->$method($args{$ext_key});
            } else {
                $if->{$ext_to_int{$ext_key}} = $args{$ext_key};
            }
        }

        $if->_init(\%args);

        foreach my $int_key (sort keys %{"${pkg_name}::_PARAMS"}){
            if ( !exists($if->{$int_key})){
                 my $disp = $int_to_ext{$int_key};
                 croak "$disp is required parameter for class $short_name. Please pass a value, or set it in the constructor\n"
            }

            # Force evaluation of default code blocks (unless lazy or replaced in the constructor)
            $if->{$int_key} = &{$if->{$int_key}}($if) if ref($if->{$int_key}) eq 'CODE' and !defined($Type::Hints::lazy->{$pkg_name}->{$int_key});
        }
        return $if;
    };


    *{"$func_name"} = Sub::Util::set_subname($prefix . $pkg_name, *{"$func_name"});

    if( $parent ) {
        # The parent constructor may have been imported into this module. We need to find the actual name of the package
        # Should this be a "can" situation?
        my $sFullPath = "${caller_pkg}::$parent";
        my $parentPackage;

        if ( exists &{$sFullPath}) {
            $parentPackage = Sub::Util::subname(\&$sFullPath);
            croak(" $sFullPath is a regular subroutine, not a Type::Hints::class") if $parentPackage !~ /^$prefix/;
            $parentPackage =~ s/^$prefix//;
            $class_longname->{$parentPackage} = 1;
        } elsif (pack_exists($parent)) {
            $parentPackage = $parent
        } else {
            croak("$parent not found. Do you need to import or load it?")
        }
        push @{"${pkg_name}::ISA"}, $parentPackage;
    }

    unshift @{ "${pkg_name}::ISA" }, 'Type::Hints::Dataclass';

    return;
}

sub resolve_ancestors {
    # Should reasonably suppoort multiple inheritance. TODO: Ensure parameter resolution order matches method resolution order
    my ($current, $pkg_name) = @_;
    no strict 'refs';

    my @pks_to_check = reverse @{"${current}::ISA"};

    if(!defined($pkg_name)){
        $pkg_name = $current;
        unshift @pks_to_check, $pkg_name;
    }

    foreach my $ancestor (@pks_to_check){
        next unless ( $class_longname->{$ancestor} );
        foreach my $parentKey (keys %{"${ancestor}::_PARAMS"}){
            if(!exists ${"${pkg_name}::_PARAMS"}{$parentKey} ){
                #Check key doesn't exist since we want to be able to override default
                ${"${pkg_name}::_PARAMS"}{$parentKey} = ${"${ancestor}::_PARAMS"}{$parentKey}; 
                $Type::Hints::defaults->{$pkg_name}->{$parentKey} = $Type::Hints::defaults->{$ancestor}->{$parentKey};
                $Type::Hints::names->{$pkg_name}->{$parentKey} = $Type::Hints::names->{$ancestor}->{$parentKey};
                $Type::Hints::lazy->{$pkg_name}->{$parentKey} = $Type::Hints::names->{$ancestor}->{$parentKey};
            }
        };
        resolve_ancestors($ancestor, $pkg_name);
    }
}


sub pack_exists {
    my $pack = shift;
    no strict 'refs'; ## no critic;

    if (scalar keys %{"${pack}::"}){
        return 1;
    } else {
        return 0;
    }
}

package Type::Hints::Dataclass;
use Scalar::Util qw(looks_like_number);
use overload '""' => \&__to_string;

sub __to_string {
    my ($self) = @_;
    no warnings qw(uninitialized);

    my @elems;
    foreach my $key (sort keys %$self) {
        my $display;
        my $val = $self->{$key};

        eval { $display = !defined($val) ? 'undef' :
                               ref($val) ? "$val"  :
                 looks_like_number($val) ? "$val"  :
                                          "'$val'" ;
            1;
        } or do {
            $display = ref($val);
        };
        push @elems, "$key=>$display";
    }
    my $sOut = join ", ", @elems;
    my $sName = ref($self);
    $sName =~ s/[\w:]+::_//;
    return "$sName($sOut)";
}

sub _init {
    my ($self, $args);
    # Do nothing, but allow being overridden;
}

1;

=head1 NAME

Type::Hints - Optional type hints and classes

=head1 SYNOPSIS

    use Type::Hints;

    class InventoryItem {
        has name: str;
        has unit_price: int;
        private quantity_available: int = 0;

        def cost($self, $quantity: int = 1) : int {
            let $cost: int = $self->unit_price * $quantity;
            return $cost;
        }
    }

=head1 DESCRIPTION

Type::Hints provides a variety of keywords that offer type annotations similar to those offered in Python and Typescript.
Syntax highlighting for these keywords is available in the Perl Navigator
A full object oriented framework written around keywords and type hints is provided as well.

=head1 KEYWORDS

=head2 let

    let $age: int = 10;

Let is similar to "my", except allows for optional type hinting.


=head2 def

    def multiply($first: num, $second: num = 1) : num {
        return $first * $second;
    }

Let is similar to "sub", except allows for optional type hinting. Importing "def" will also enable subroutine signatures


=head2 has

    package Airport {
        has airplanes: arrayref[ int | str];
        has name: str;
        has regional: bool = 1;

        sub new {
            my ($class, %args) = @_;
            return bless \%args, $class;
        }
    }

    my $airport = Airport->new(name=>'Nantucket');
    print $airport->name "is a regional airport" if($airport->regional);

Has will define new attributes for use in classes. It accepts type hints and specifies default arguments. An accessor and an l-value setter will be generated for each attribute.
"has" is best with classes, but works with normal packages as well. If you build your own object system, you'll need to deal with ->new() and ensuring the relevant args were passed.


=head3 public
    public is a synonym for has

    class Airport {
        public name: str;
    }

=head3 private
    private restricts read and write access class in which a variable was created

    class Airport {
        private name: str;
    }

=head3 protected
    protected restricts read and write access to the enclosing class and subclasses. 

    class Airport {
        protected name: str;
    }

=head3 readonly
    readonly defines an object that can be read, but not written to. This also blocks writing to it from within the object itself

    class Airport {
        readonly name: str;
    }

=head3 lazy
lazy is relevant when the default is a sub{}. Lazy attributes are initialized on the first get, instead of in the constructor.
If you not using class (e.g. using 'has' in a regular package), then all attributes are lazy due to the lack of constructor.

    class Airport {
        lazy radar: sub { RadarTower->new() }; # Expensive object to build. Only build if needed.
    }

=head3 initvar
initvars are used to allow extra parameters into the constructor that are not attributes of the class. These are style after Python dataclasses InitVars.

    class Color {
        private color: str;
        initvar red: int;
        initvar green: int;
        initvar blue: int;

        _init($self, Color){
            $self->color = "RGB($args->{red},$args->{green}, $args->{blue})";
        }
    }

=head2 class

    class Person {
        has name: str;
        has age: int;
        has alive: bool = 1;

        def _init($self, $args){
            die("Ages can't be negative") if $self->age < 0;
        }
    }

    my $Bob = Person(name=>"Robert", age=>55);
    say "Happy Birthday " . $Bob->name;
    $Bob->age = 56;
    print($Bob);

classes are styled after Python dataclasses and somewhat resemble Typescript interfaces. 
A class will generate a constructor of the same name and requires all arguments that do not have defaults.
Attributes can be accessed as methods, and can be modified using l-value methods. 

class also overload the string operation and offer a pretty-printed display of the object contents

Any parameter without a default specified is a required parameter. It needs to either be passed to the constructor or set inside the constructor. 

=head3 Lexical Constructor
Contrary to normal packages, class constructors are local only to the package in which they are defined. 
This is an important feature of classes, which often may be small data-oriented classes where a full package including distinct file may not make sense.

For example, imagine I am writing a Perl::Critic policy named Perl::Critic::Policy::ValuesAndExpressions::ProhibitLargeComplexNumbers that prohibits some specific types of complex numbers.
As part of this, perhaps I decide to build a class consisting of two attributes: real and imaginary. This appears to be a simple class, but unfortunately all packages in Perl are global, so I should not use the name "ComplexPoint".
Convention and practicality dictate that I name my class Perl::Critic::Policy::ValuesAndExpressions::ProhibitLargeComplexNumbers::ComplexPoint and create a new file for it named Perl/Critic/Policy/ValuesAndExpressions/ProhibitLargeComplexNumbers/ComplexPoint.pm 
that defines my two new fields and a constructor. This becomes quite a pain to type and results in many authors simply not using classes for smaller data-oriented object.

Classes are intended to make small object construction simple while not interfering with other modules across your codebase or across CPAN. 
Defining class Baz within in package Foo::Bar  will auto-generate a new package name Foo::Bar::_Baz and build a subroutine constructor in the same package.
As a subroutine, the constructor may be exported to any module needing this class.  


=head3 _init

    class Person {
        has name : str;
        has age  : int;
        has surprise_party : Party::Plan | undef = undef;
        def _init( $self, $args ) {
            die("Ages can't be negative")                if $self->age < 0;
            die("Nobody names their child empty string") if $self->name eq "";
            $self->surprise_party = Party::Plan->new( guest_of_honor => $self->name ) unless defined($self->surprise_party);
        }
    }

The optional _init method is called immediately after the class is built and allows an opporutunity for data validation and object initialization.
_init is passed $args, but this is rarely necessary to consult unless you need to differentiate between default arguments and arguments passed to the constructor.

=head3 Getters and Setters

If you need data validation on the lvalue getters and setters, you may add a get_foo or set_foo, which will be called automatically on the get and set respectively

    class Account {
        has balance = 0;
        sub get_balance($self) {
            # Log access to the account for security reasons.
            print "Accessing balance\n";
            return $self->balance;
        }
        sub set_balance($self, $value) {
            # More than just a type constraint, perhaps we want alert someone if overdraft attempted
            croak("Overdraft fee applied!") if ($value < 0);
            $self->balance = $value;
        }
    }
    my $account = Account(balance=>100);
    $account->balance -= 10; # Calls a get and a set

These accessors allow you to start developing with normal lvalue accessors and only add validation after the fact without requiring refactoring your code to use getters and setters.

The equivalent style in python is
    @property
    def balance(self):
        return self._balance

    @balance.setter
    def balance(self, value):
        self._balance = value

and the equivalent in typescript is:

    get balance(): number {
        return this._balance;
    }
    set balance(value: number) {
        this._balance = value;
    }

=head3 Inheritance
Single inheritance is supported. You can either subclass from Type::hints style classes, or from normal packages.
Because you can inherit from packages that themselves may use multiple inheritance from Type::Hints classes, you may effectively end up with multiple inheritance on classes. This feature does work, but is experimental.

    class Animal {
    }

    class Dog extends Animal {
    }


=head2 Available Hints

Type hints are validated at compilation time to ensure the hint itself is valid (although it does not check the variable data).
The allowed hints are: int, num, bool, str, undef, object, array, arrayref, hash, hashref, coderef, scalarref, and inline object definitions 

The type hints are composable using the or operator | and using various hints as containers. For example:

    let $foo: arrayref[ int | object | arrayref[str]] | undef; 
    let $bar: {arg1 : str, arg2: int, myInts: arrayref[Math::BigInt | int] };

All primitive hints are always available and do not need to be imported from Type::Hints. However, you can explicitly import hints if you want to satisfy Perl::Critic or generally prefer the readability.


=head2 What about attributes?

Many people will notice that Type::Hints uses the :int syntax otherwise used for variable attributes. 
Subroutine attributes are not impacted by this notation as they occur prior to signature. 

In my experience, variable attributes are rare and often unnecessary. There is only a single built-in variable attribute "shared" that is for use with threads. 
Unless you are doing threading in perl, this conflict will not be an issue. Currently subroutine signatures do not allow for any attributes in the variable definition, so there is no conflict when using "def" over "sub".
Perl::Critic and Perl::Tidy also work very well using this notation as they were designed with the expectation of variable attributes.

There is precedent for repurposing less used notation with subroutine signatures. Enabling signatures will prevent the use of prototypes.

An alternate syntax I have explored is the use of ~ instead of :. This is seen in statistics when definining the distribution of a variable such as Height ~ N(μ, σ).
The tilde is also used in linguistics to represent alternating allomorphs. Type::Hints do not specify that a variable will exactly match a type, but simply be allomorphic to that type (i.e. implement the same features). 
Perl currently uses the tilde in boolean logic, but Type::Hints also repurposes the symbol | from boolean logic so will never be allowed where boolean logic could be applied.

If you prefer, Type::Hints currently supports ~ as an alernative syntax for hints, and it may be used interchangeably with the colon syntax.

    class InventoryItem {
        has name       ~ str;
        has unit_price ~ int;
        has quantity_available ~ int = 0;

        def cost( $self, $quantity ~ int = 1 ) ~ int {
            let $cost ~ int = $self->unit_price * $quantity;
            return $cost;
        }
    }

=head2 Runtime impact

Type::Hints does not validate data types or have any runtime impact on your application. This is consistent with the Type annotation behaviours of both Python and Typescript. 

This makes Type::Hints safe as a method for gradually modernizing and documenting the code of legacy applications. As it has no runtime impact, it is unlikely to throw any runtime errors if the script itself can compile.
classes (much like regular objects) also allow for hash based accessing of attributes and can be used as drop-in replacement for instances where you would otherwise pass around hash references.
classes allow centralizing the definition of the class including the more explicity use of default values. These aspects are what make the classes reminiscent of Typescript interfaces. 

=head2 Moo/Moose compatibility
Type::Hints are fully compatible with Moo/Moose/Mo/Mouse and similar object frameworks. For attributes, you can use public, private, and readonly and they work including defaults, lvalues, and access control.
However, these attributes are not allowed in Moo/Moose constructors so you will need another method of assigning values (perhaps in the BUILD function)
Let and def both work as well and work as expected. You can also use all of these function in ordinary packages as well if you prefer the built-in Perl OO system. 

=head1 LICENSE

Copyright (C) bscan.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

bscan E<lt>10503608+bscan@users.noreply.github.comE<gt>

=cut

