# NAME

Data::Class - Data classes and type hints for Perl.

## SYNOPSIS

Screenshot includes the syntax highlighting found in the Perl Navigator

![Example](https://raw.githubusercontent.com/bscan/Type-Hints/main/images/catfood.png)


## DESCRIPTION

Data::Class provides a variety of keywords that offer classes similar to dataclasses in Python, and type hints
similar to those offered in Python and Typescript. These keywords are not limited to usage inside of a class. Syntax highlighting
for these keywords is available in the Perl Navigator. 

# KEYWORDS

### let

``` typescript
let $age: int = 10;
```

Let is similar to "my", except allows for optional type hinting.

### def

``` 
def multiply($first: num, $second: num = 1) : num {
    return $first * $second;
}
```

Let is similar to "sub", except allows for optional type hinting.
Importing "def" will also enable subroutine signatures

### has

```
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
print $airport->name . " is a regional airport" if($airport->regional);
```

Has will define new attributes for use in classes and packages. It accepts type
hints and specifies default arguments. An accessor and an l-value
setter will be generated for each attribute. "has" is best with
classes, but works with normal packages as well. If you build your own
object system, you'll need to deal with ->new() and ensuring the
relevant args were passed.

### public
When used for definining attributes, public is a synonym for has.
When used as a modifier to sub or def, public does not do anything, but may clarify the usage of a method

``` typescript
class Airport {
    public name: str;

    public sub($self) { return 42 }
}
```

### private
private restricts access to the class in which a variable or method is defined

``` typescript
class Airport {
    private name: str;

    private sub($self) { return 42 }
}
```

### protected
protected restricts read and write access to the enclosing
class and subclasses.

``` typescript
class Airport {
    protected name: str;

    private def($self) { return 42 }
}
```

### readonly
readonly defines an object that can be read, but not written to.
This also blocks writing to it from within the object itself

``` typescript
class Airport {
    readonly name: str;
}
```

### lazy
lazy is relevant when the default is a sub{}. Lazy attributes are
initialized on the first get, instead of in the constructor. If you not
using class (e.g. using 'has' in a regular package), then all attributes
are lazy due to the lack of constructor. Useful if you have an expensive object to build
and only want to build as needed.

```
class Airport {
    lazy radar = sub { RadarTower->new() }; 
}
```

### initvar
initvars are used to allow extra parameters into the constructor
that are not attributes of the class. These are style after Python
dataclasses InitVars.

```
class Color {
    private color: str;
    initvar red: int;
    initvar green: int;
    initvar blue: int;

    def _init($self, $args){
        $self->color = "RGB($args->{red},$args->{green}, $args->{blue})";
    }
}
```

## class

```
class Person {
    has name: str;
    has age: int;
    private alive: bool = 1;

    def _init($self, $args){
        die("Ages can't be negative") if $self->age < 0;
    }
}

my $Bob = Person->new(name=>"Robert", age=>55);
say "Happy Birthday " . $Bob->name;
$Bob->age = 56;
print($Bob);
```

classes are styled after Python dataclasses and somewhat resemble
Typescript interfaces. All arguments that do not have defaults are required in new. Attributes
can be accessed as methods, and can be modified using l-value methods.

class also overload the string operation and offer a pretty-printed
display of the object's contents

Any parameter in a class without a default specified is a required parameter. It
needs to either be passed to the constructor or set inside the
constructor. This does not apply to `has` statements in normal packages


## _init

```
class Person {
    has name : str;
    has age  : int;
    has surprise_party : Party::Plan;
    def _init( $self, $args ) {
        die("Ages can't be negative")                if $self->age < 0;
        die("Nobody names their child empty string") if $self->name eq "";
        $self->surprise_party = Party::Plan->new( guest_of_honor => $self->name ) unless defined($self->surprise_party);
    }
}
```

The optional _init method is called immediately after the class is
built and allows an opportunity for data validation and object
initialization. _init is passed $args although this is primarily only used for initvars.

## Getters and Setters

If you need data validation on the lvalue getters and setters, you may
add a get foo() or set foo(), which will be called automatically on the get
and set respectively

``` perl 
class Account {
    has balance = 0;
    get balance($self) {
        # Log access to the account for security reasons.
        print "Accessing balance\n";
        return $self->balance;
    }
    set balance($self, $value: int) {
        # More than just a type constraint, perhaps we want alert someone if overdraft attempted
        croak("Overdraft fee applied!") if ($value < 0);
        $self->balance = $value;
    }
}
my $account = Account(balance=>100);
$account->balance -= 10; # Calls a get and a set
```

These accessors allow you to start developing with normal lvalue
accessors and only add validation after the fact without requiring
refactoring your code to use getters and setters.


The equivalent style in typescript is

``` typescript
class Account {
    private _balance: number = 0;
    
    get balance(): number {
        return this._balance;
    }
    set balance(value: number) {
        this._balance = value;
    }
}
```

and the equivalent in python is:

``` python
@dataclass
class Account:
    _balance: int = 0
    @property
    def balance(self):
        return self._balance

    @balance.setter
    def balance(self, value):
        self._balance = value
```


## Inheritance
Single inheritance is supported. You can either subclass from
Data::Class classes, or from normal packages. Because you can
inherit from packages that themselves may use multiple inheritance from
Data::Class classes, you may effectively end up with multiple inheritance
on classes. This feature does work, but is experimental.

``` typescript
class Animal {
}

class Dog extends Animal {
}
```
Available Hints

Type hints are validated at compilation time to ensure the hint itself
is valid (although it does not check the variable data). The allowed
hints are: int, num, bool, str, undef, object, array, arrayref, hash,
hashref, coderef, scalarref, and inline object definitions

The type hints are composable using the or operator | and using various
hints as containers. For example:

``` typescript
let $foo: arrayref[ int | object | arrayref[str]] | undef; 
let $bar: {arg1 : str, arg2: int, myInts: arrayref[Math::BigInt | int] };
```

All primitive hints are always available and do not need to be imported
from Data::Class. However, you can explicitly import hints if you want
to satisfy Perl::Critic or generally prefer the readability.

### What about attributes?

Many people will notice that Data::Class uses the :int syntax otherwise
used for variable attributes. Subroutine attributes are not impacted by
this notation as they occur prior to signature.

In my experience, variable attributes are rare and often unnecessary.
There is only a single built-in variable attribute "shared" that is for
use with threads. Unless you are doing threading in perl, this conflict
will not be an issue. Currently subroutine signatures do not allow for
any attributes in the variable definition, so there is no conflict when
using "def" over "sub". Perl::Critic and Perl::Tidy also work very well
using this notation as they were designed with the expectation of
variable attributes.

There is precedent for repurposing less used notation with subroutine
signatures. Enabling signatures will prevent the use of prototypes.

An alternate syntax I have explored is the use of ~ instead of :. This
is seen in statistics when definining the distribution of a variable
such as Height ~ N(μ, σ). The tilde is also used in linguistics to
represent alternating allomorphs. Data::Class do not specify that a
variable will exactly match a type, but simply be allomorphic to that
type (i.e. implement the same features). Perl currently uses the tilde
in boolean logic, but Data::Class also repurposes the symbol | from
boolean logic so will never be allowed where boolean logic could be
applied.

If you prefer, Data::Class currently supports ~ as an alernative syntax
for hints, and it may be used interchangeably with the colon syntax.

```
class InventoryItem {
    has name       ~ str;
    has unit_price ~ int;
    has quantity_available ~ int = 0;

    def cost( $self, $quantity ~ int = 1 ) ~ int {
        let $cost ~ int = $self->unit_price * $quantity;
        return $cost;
    }
}
```

### Runtime impact

Type hints do not validate data types or have any runtime impact on
your application. This is consistent with the Type annotation
behaviours of both Python and Typescript.

This makes Data::Class safe as a method for gradually modernizing and
documenting the code of legacy applications. As it has no runtime
impact, it is unlikely to throw any runtime errors if the script itself
can compile. classes (much like regular objects) also allow for hash
based accessing of attributes and can be used as drop-in replacement
for instances where you would otherwise pass around hash references.
classes allow centralizing the definition of the class including the
more explicity use of default values. These aspects are what make the
classes reminiscent of Typescript interfaces.

## Moo/Moose compatibility
Data::Class is fully compatible with Moo/Moose/Mo/Mouse and similar object frameworks. For attributes, you can
use public, private, and readonly and they work including defaults,
lvalues, and access control. However, these attributes are not allowed in
Moo/Moose constructors so you will need another method of assigning values
(perhaps in the BUILD function) Let and def both work as well and work as
expected. You can also use all of these function in ordinary packages as
well if you prefer the built-in Perl OO system.
