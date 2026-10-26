<?xml version="1.0" encoding="UTF-8"?>
<!-- Profile 3 of test/compat_test.py: turns page.xml into an HTML list. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8"/>
  <xsl:template match="/items">
    <html><body><ul>
      <xsl:for-each select="item">
        <xsl:sort select="@id" data-type="number" order="descending"/>
        <li id="{@id}"><xsl:value-of select="."/> (<xsl:value-of select="string-length(.)"/>)</li>
      </xsl:for-each>
    </ul></body></html>
  </xsl:template>
</xsl:stylesheet>
