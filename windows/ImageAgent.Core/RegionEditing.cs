using System.Text.Json;
using System.Text.Json.Serialization;

namespace ImageAgent.Core;
public readonly record struct ImagePoint(double X, double Y)
{
    [JsonIgnore]
    public bool Finite => double.IsFinite(X) && double.IsFinite(Y);
}

public readonly record struct PixelRect(int X, int Y, int Width, int Height);
public record RegionMark(string Kind, ImagePoint[] Points, double Diameter = 0);
[JsonConverter(typeof(RegionSelectionConverter))]
public sealed class RegionSelection
{
    public int Width { get; }
    public int Height { get; }

    readonly List<RegionMark> marks = [];
    public IReadOnlyList<RegionMark> Marks => marks;

    bool? empty;
    internal void AddStoredMark(RegionMark mark)
    {
        marks.Add(mark);
        empty = null;
    }

    public RegionSelection(int width, int height)
    {
        DecodedImage.ValidateDimensions(width, height);
        Width = width;
        Height = height;
    }

    public RegionSelection Clone() => SwiftJson.Decode<RegionSelection>(SwiftJson.Encode(this));
    public bool CanUndo => Marks.Count > 0;
    public bool IsEmpty => empty ??= !Coverage().Any(p => p != 0);

    bool Capacity(int points) => Marks.Count < 4096 && Marks.Sum(m => m.Points.Length) + points <= 100000;
    public void AddRectangle(ImagePoint a, ImagePoint b)
    {
        if (!a.Finite || !b.Finite || a.X == b.X || a.Y == b.Y || Math.Max(a.X, b.X) <= 0 || Math.Max(a.Y, b.Y) <= 0 || Math.Min(a.X, b.X) >= Width || Math.Min(a.Y, b.Y) >= Height)
            return;
        if (!Capacity(2))
            throw new AgentException("选区笔画或点数过多。");
        AddStoredMark(new("rectangle", [new(Math.Max(0, Math.Min(a.X, b.X)), Math.Max(0, Math.Min(a.Y, b.Y))), new(Math.Min(Width, Math.Max(a.X, b.X)), Math.Min(Height, Math.Max(a.Y, b.Y)))]));
    }

    public void AddPen(IEnumerable<ImagePoint> points)
    {
        var input = points.ToArray();
        if (input.Length < 3 || input.Any(p => !p.Finite))
            return;
        var polygon = new List<ImagePoint>();
        foreach (var p in input)
            if (polygon.Count == 0 || polygon[^1] != p)
                polygon.Add(p);
        if (polygon.Count > 0 && polygon[0] == polygon[^1])
            polygon.RemoveAt(polygon.Count - 1);
        foreach (var(axis, boundary, greater)in new[]
        {
            (0, 0d, true),
            (0, (double)Width, false),
            (1, 0d, true),
            (1, (double)Height, false)
        }

        )
        {
            if (polygon.Count < 3)
                return;
            double Coordinate(ImagePoint p) => axis == 0 ? p.X : p.Y;
            bool Inside(ImagePoint p) => greater ? Coordinate(p) >= boundary : Coordinate(p) <= boundary;
            var clipped = new List<ImagePoint>();
            var previous = polygon[^1];
            foreach (var p in polygon)
            {
                if (Inside(previous) != Inside(p))
                {
                    var a = Coordinate(previous);
                    var b = Coordinate(p);
                    var scale = Math.Max(1, Math.Max(Math.Abs(a), Math.Max(Math.Abs(b), Math.Abs(boundary))));
                    var t = (boundary / scale - a / scale) / (b / scale - a / scale);
                    var other = axis == 0 ? previous.Y * (1 - t) + p.Y * t : previous.X * (1 - t) + p.X * t;
                    var at = axis == 0 ? new ImagePoint(boundary, other) : new ImagePoint(other, boundary);
                    if (!at.Finite)
                        return;
                    if (clipped.Count == 0 || clipped[^1] != at)
                        clipped.Add(at);
                }

                if (Inside(p) && (clipped.Count == 0 || clipped[^1] != p))
                    clipped.Add(p);
                previous = p;
            }

            if (clipped.Count > 0 && clipped[0] == clipped[^1])
                clipped.RemoveAt(clipped.Count - 1);
            polygon = clipped;
        }

        if (polygon.Count >= 3 && Spans(polygon.ToArray(), (_, _, _) => true))
        {
            if (!Capacity(polygon.Count))
                throw new AgentException("选区笔画或点数过多。");
            AddStoredMark(new("pen", polygon.ToArray()));
        }
    }

    public void AddBrush(ImagePoint[] p, double diameter)
    {
        if (p.Length == 0 || p.Any(x => !x.Finite) || !double.IsFinite(diameter) || diameter <= 0)
            return;
        if (!Capacity(p.Length))
            throw new AgentException("选区笔画或点数过多。");
        AddStoredMark(new("brush", p, Math.Min(diameter, Math.Max(Width, Height) * 2d)));
    }

    public void Undo()
    {
        if (Marks.Count > 0)
            marks.RemoveAt(Marks.Count - 1);
        empty = null;
    }

    public void Clear()
    {
        marks.Clear();
        empty = null;
    }

    bool Spans(ImagePoint[] points, Func<int, int, int, bool> visit)
    {
        int top = Math.Max(0, (int)Math.Floor(points.Min(p => p.Y))), bottom = Math.Min(Height, (int)Math.Ceiling(points.Max(p => p.Y)));
        for (int y = top; y < bottom; y++)
        {
            var cy = y + .5;
            var intersections = new List<double>();
            var previous = points[^1];
            foreach (var p in points)
            {
                if ((previous.Y > cy) != (p.Y > cy))
                    intersections.Add(previous.X + (cy - previous.Y) / (p.Y - previous.Y) * (p.X - previous.X));
                previous = p;
            }

            intersections.Sort();
            for (int i = 0; i + 1 < intersections.Count; i += 2)
            {
                int left = Math.Clamp((int)Math.Ceiling(intersections[i] - .5), 0, Width), right = Math.Clamp((int)Math.Ceiling(intersections[i + 1] - .5), 0, Width);
                if (left < right && visit(y, left, right))
                    return true;
            }
        }

        return false;
    }

    public byte[] Coverage()
    {
        var a = new byte[Width * Height];
        static int Bound(double v, int max, bool ceil = false) => (int)Math.Clamp(ceil ? Math.Ceiling(v) : Math.Floor(v), 0, max);
        foreach (var mark in Marks)
        {
            var p = mark.Points;
            if (mark.Kind == "rectangle")
            {
                int left = Bound(p[0].X, Width), right = Bound(p[1].X, Width, true), top = Bound(p[0].Y, Height), bottom = Bound(p[1].Y, Height, true);
                for (int y = top; y < bottom; y++)
                    Array.Fill(a, (byte)255, y * Width + left, right - left);
            }
            else if (mark.Kind == "pen")
                Spans(p, (y, l, r) =>
                {
                    Array.Fill(a, (byte)255, y * Width + l, r - l);
                    return false;
                });
            else
            {
                if (p.Length == 1 && p[0].X >= 0 && p[0].X < Width && p[0].Y >= 0 && p[0].Y < Height)
                    a[(int)p[0].Y * Width + (int)p[0].X] = 255;
                double radius = mark.Diameter / 2;
                for (int i = 0; i < Math.Max(1, p.Length - 1); i++)
                {
                    var v = p[i];
                    var b = p[Math.Min(i + 1, p.Length - 1)];
                    int l = Bound(Math.Min(v.X, b.X) - radius, Width), r = Bound(Math.Max(v.X, b.X) + radius, Width, true), t = Bound(Math.Min(v.Y, b.Y) - radius, Height), bottom = Bound(Math.Max(v.Y, b.Y) + radius, Height, true);
                    var dx = b.X - v.X;
                    var dy = b.Y - v.Y;
                    var length = dx * dx + dy * dy;
                    for (int y = t; y < bottom; y++)
                        for (int x = l; x < r; x++)
                        {
                            var u = length > 0 ? Math.Clamp(((x + .5 - v.X) * dx + (y + .5 - v.Y) * dy) / length, 0, 1) : 0;
                            var ex = x + .5 - (v.X + u * dx);
                            var ey = y + .5 - (v.Y + u * dy);
                            if (ex * ex + ey * ey <= radius * radius)
                                a[y * Width + x] = 255;
                        }
                }
            }
        }

        return a;
    }
}

public sealed class RegionSelectionConverter : JsonConverter<RegionSelection>
{
    public override RegionSelection Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
    {
        using var d = JsonDocument.ParseValue(ref r);
        var e = d.RootElement;
        var selection = new RegionSelection(e.GetProperty("width").GetInt32(), e.GetProperty("height").GetInt32());
        var marks = e.GetProperty("marks").EnumerateArray().ToArray();
        if (marks.Length > 4096)
            throw new AgentException("保存的选区笔画过多。");
        int count = 0;
        foreach (var m in marks)
        {
            var props = m.EnumerateObject().ToArray();
            if (props.Length != 1)
                throw new AgentException("保存的选区笔画无效。");
            var p = props[0];
            ImagePoint Point(JsonElement v) => new(v.GetProperty("x").GetDouble(), v.GetProperty("y").GetDouble());
            bool Inside(ImagePoint v) => v.Finite && v.X >= 0 && v.Y >= 0 && v.X <= selection.Width && v.Y <= selection.Height;
            ImagePoint[] points;
            double diameter = 0;
            if (p.Name == "rectangle")
            {
                points = [Point(p.Value.GetProperty("_0")), Point(p.Value.GetProperty("_1"))];
                if (points.Any(v => !Inside(v)) || points[0].X >= points[1].X || points[0].Y >= points[1].Y)
                    throw new AgentException("保存的方框选区无效。");
            }
            else if (p.Name is "pen" or "brush")
            {
                points = p.Value.GetProperty("_0").EnumerateArray().Select(Point).ToArray();
                if (p.Name == "pen" && (points.Length < 3 || points.Any(v => !Inside(v))))
                    throw new AgentException("保存的钢笔选区无效。");
                if (p.Name == "brush")
                {
                    diameter = p.Value.GetProperty("_1").GetDouble();
                    if (points.Length == 0 || points.Any(v => !v.Finite || Math.Abs(v.X) > 1e9 || Math.Abs(v.Y) > 1e9) || !double.IsFinite(diameter) || diameter <= 0 || diameter > Math.Max(selection.Width, selection.Height) * 2d)
                        throw new AgentException("保存的笔刷选区无效。");
                }
            }
            else
                throw new AgentException("保存的选区类型无效。");
            count += points.Length;
            if (count > 100000)
                throw new AgentException("选区点数过多。");
            selection.AddStoredMark(new(p.Name, points, diameter));
        }

        return selection;
    }

    public override void Write(Utf8JsonWriter w, RegionSelection v, JsonSerializerOptions o)
    {
        w.WriteStartObject();
        w.WriteNumber("width", v.Width);
        w.WriteNumber("height", v.Height);
        w.WritePropertyName("marks");
        w.WriteStartArray();
        foreach (var m in v.Marks)
        {
            w.WriteStartObject();
            w.WritePropertyName(m.Kind);
            w.WriteStartObject();
            w.WritePropertyName("_0");
            if (m.Kind == "rectangle")
            {
                JsonSerializer.Serialize(w, m.Points[0], o);
                w.WritePropertyName("_1");
                JsonSerializer.Serialize(w, m.Points[1], o);
            }
            else
            {
                JsonSerializer.Serialize(w, m.Points, o);
                if (m.Kind == "brush")
                    w.WriteNumber("_1", m.Diameter);
            }

            w.WriteEndObject();
            w.WriteEndObject();
        }

        w.WriteEndArray();
        w.WriteEndObject();
    }
}

public record RegionEditRequest(string AssetID, RegionSelection Selection);
public sealed class RegionEditSnapshot
{
    public PixelImage Base { get; }
    public byte[] Coverage { get; }
    public PixelRect ROI { get; }
    public byte[] ImagePNG { get; }
    public byte[] MaskPNG { get; }

    public RegionEditSnapshot(PixelImage image, RegionSelection selection, int? contextPadding = null)
    {
        if (selection.Width != image.Width || selection.Height != image.Height)
            throw new AgentException("选区与原图尺寸不匹配。");
        Base = image;
        Coverage = selection.Coverage();
        int l = image.Width, t = image.Height, r = 0, b = 0;
        for (int y = 0; y < image.Height; y++)
            for (int x = 0; x < image.Width; x++)
                if (Coverage[y * image.Width + x] > 0)
                {
                    l = Math.Min(l, x);
                    t = Math.Min(t, y);
                    r = Math.Max(r, x + 1);
                    b = Math.Max(b, y + 1);
                }

        if (l >= r || t >= b)
            throw new AgentException("请先在图片上选择需要修改的区域。");
        int pad = Math.Clamp(contextPadding ?? Math.Max(16, Math.Min(128, Math.Max(r - l, b - t) / 5)), 0, Math.Max(image.Width, image.Height));
        l = Math.Max(0, l - pad);
        t = Math.Max(0, t - pad);
        r = Math.Min(image.Width, r + pad);
        b = Math.Min(image.Height, b + pad);
        ROI = new(l, t, r - l, b - t);
        ImagePNG = image.Crop(ROI).PngData();
        var mask = new byte[ROI.Width * ROI.Height * 4];
        for (int y = 0; y < ROI.Height; y++)
            for (int x = 0; x < ROI.Width; x++)
                mask[(y * ROI.Width + x) * 4 + 3] = (byte)(255 - Coverage[(y + t) * image.Width + x + l]);
        MaskPNG = new PixelImage(ROI.Width, ROI.Height, mask).PngData();
        if (MaskPNG.Length >= 4 * 1024 * 1024)
            throw new AgentException("选区遮罩超过 4MB，请缩小选区。");
    }

    byte[]? Feather()
    {
        int w = ROI.Width, h = ROI.Height, cap = 73;
        var depth = Enumerable.Repeat((byte)cap, w * h).ToArray();
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (Coverage[(y + ROI.Y) * Base.Width + x + ROI.X] == 0)
                    depth[y * w + x] = 0;
        int Neighbor(int x, int y)
        {
            if (x >= 0 && x < w && y >= 0 && y < h)
                return depth[y * w + x];
            int ix = x + ROI.X, iy = y + ROI.Y;
            return ix >= 0 && ix < Base.Width && iy >= 0 && iy < Base.Height ? 0 : cap;
        }

        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (depth[y * w + x] > 0)
                    depth[y * w + x] = (byte)Math.Min(depth[y * w + x], Math.Min(Math.Min(Neighbor(x - 1, y), Neighbor(x, y - 1)), Math.Min(Neighbor(x - 1, y - 1), Neighbor(x + 1, y - 1))) + 1);
        for (int y = h - 1; y >= 0; y--)
            for (int x = w - 1; x >= 0; x--)
                if (depth[y * w + x] > 0)
                    depth[y * w + x] = (byte)Math.Min(depth[y * w + x], Math.Min(Math.Min(Neighbor(x + 1, y), Neighbor(x, y + 1)), Math.Min(Neighbor(x - 1, y + 1), Neighbor(x + 1, y + 1))) + 1);
        if (depth.Max() < 8)
            return null;
        var weights = new byte[depth.Length];
        var component = new List<int>();
        for (int start = 0; start < depth.Length; start++)
            if (depth[start] > 0 && depth[start] < 128)
            {
                component.Clear();
                component.Add(start);
                depth[start] |= 128;
                int cursor = 0, max = 0;
                while (cursor < component.Count)
                {
                    int index = component[cursor++];
                    max = Math.Max(max, depth[index] & 127);
                    int x = index % w, y = index / w;
                    for (int dy = -1; dy <= 1; dy++)
                        for (int dx = -1; dx <= 1; dx++)
                        {
                            int nx = x + dx, ny = y + dy;
                            if (nx < 0 || nx >= w || ny < 0 || ny >= h)
                                continue;
                            int next = ny * w + nx;
                            if (depth[next] > 0 && depth[next] < 128)
                            {
                                depth[next] |= 128;
                                component.Add(next);
                            }
                        }
                }

                int radius = max < 8 ? 0 : Math.Min(12, max / 6);
                foreach (int i in component)
                {
                    double v = radius == 0 ? 1 : Math.Min(1, (double)(depth[i] & 127) / (radius + 1));
                    weights[i] = (byte)Math.Round(v * v * (3 - 2 * v) * 255, MidpointRounding.AwayFromZero);
                }
            }

        return weights;
    }

    public PixelImage Composite(PixelImage patch)
    {
        patch = patch.Resize(ROI.Width, ROI.Height, Base.ICC);
        var feather = Feather();
        var result = (byte[])Base.RGBA.Clone();
        for (int y = 0; y < ROI.Height; y++)
            for (int x = 0; x < ROI.Width; x++)
            {
                int dst = (y + ROI.Y) * Base.Width + x + ROI.X;
                if (Coverage[dst] == 0)
                    continue;
                int local = y * ROI.Width + x, weight = Coverage[dst] * (feather?[local] ?? 255) / 255;
                for (int c = 0; c < 4; c++)
                    result[dst * 4 + c] = (byte)((patch.RGBA[local * 4 + c] * weight + Base.RGBA[dst * 4 + c] * (255 - weight) + 127) / 255);
            }

        return new(Base.Width, Base.Height, result, Base.ICC);
    }
}
