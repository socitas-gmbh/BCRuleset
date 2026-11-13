codeunit 50100 "SOC Cust"
{
    // Mentions LC0010 in an ordinary comment, must stay untouched.
#pragma warning disable LC0010, AA0137
    procedure Foo()
    begin
    end;
#pragma warning restore LC0010
#pragma warning disable LC0029
    procedure Bar()
    begin
    end;
#pragma warning restore LC0029
}
