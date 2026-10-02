namespace Poc.Api.Authorization;

public static class Policies
{
    /// <summary>Delegated scope the SPA must present on every call (api://&lt;api-client-id&gt;/access_as_user).</summary>
    public const string ApiScope = "access_as_user";

    /// <summary>App role assigned in Entra ID that unlocks editing other users' directory data.</summary>
    public const string ApplicationAdminRole = "ApplicationAdmin";

    /// <summary>Authorization policy name; requires <see cref="ApplicationAdminRole"/>.</summary>
    public const string CanEditUsers = "CanEditUsers";
}

public static class GraphScopes
{
    /// <summary>Delegated Graph permission requested on-behalf-of the caller only when writing users.</summary>
    public const string UserWrite = "User.ReadWrite.All";
}
