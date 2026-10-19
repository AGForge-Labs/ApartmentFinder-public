Add-Type -AssemblyName System.Drawing
$iconPath = Join-Path $PSScriptRoot '../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
$bitmap = New-Object System.Drawing.Bitmap(1024,1024,[System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::FromArgb(14,25,36))
$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(236,246,249))
$mint = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70,220,182))
$dark = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(14,25,36))
$outline = New-Object System.Drawing.Pen($white,34)
$graphics.DrawRectangle($outline,245,224,380,550)
foreach ($x in @(315,485)) {
    foreach ($y in @(310,455)) { $graphics.FillRectangle($white,$x,$y,70,70) }
}
$graphics.FillRectangle($mint,365,635,140,139)
$graphics.FillEllipse($mint,601,322,220,220)
$triangle = [System.Drawing.Point[]]@([System.Drawing.Point]::new(620,495),[System.Drawing.Point]::new(802,495),[System.Drawing.Point]::new(711,660))
$graphics.FillPolygon($mint,$triangle)
$graphics.FillEllipse($dark,667,386,88,88)
$bitmap.Save($iconPath,[System.Drawing.Imaging.ImageFormat]::Png)
$outline.Dispose()
$white.Dispose()
$mint.Dispose()
$dark.Dispose()
$graphics.Dispose()
$bitmap.Dispose()
