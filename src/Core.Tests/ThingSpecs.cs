using Core;
using Xunit;

namespace Core.Tests;

public sealed class ThingSpecs
{
    [Fact]
    public void Thing_has_a_name()
    {
        Assert.Equal("thing", new Thing().Name);
    }
}
