'''
Vertex Instructions
===================

This module includes all the classes for drawing simple vertex objects.

Updating properties
-------------------

The list attributes of the graphics instruction classes (e.g.
:attr:`Triangle.points`, :attr:`Mesh.indices` etc.) are not Kivy
properties but Python properties. As a consequence, the graphics will only
be updated when the list object itself is changed and not when list values
are modified.

For example in python:

.. code-block:: python

    class MyWidget(Button):

        triangle = ObjectProperty(None)
        def __init__(self, **kwargs):
            super(MyWidget, self).__init__(**kwargs)
            with self.canvas:
                self.triangle = Triangle(points=[0,0, 100,100, 200,0])

and in kv:

.. code-block:: kv

    <MyWidget>:
        text: 'Update'
        on_press:
            self.triangle.points[3] = 400

Although pressing the button will change the triangle coordinates,
the graphics will not be updated because the list itself has not
changed. Similarly, no updates will occur using any syntax that changes
only elements of the list e.g. self.triangle.points[0:2] = [10,10] or
self.triangle.points.insert(10) etc.
To force an update after a change, the list variable itself must be
changed, which in this case can be achieved with:

.. code-block:: kv

    <MyWidget>:
        text: 'Update'
        on_press:
            self.triangle.points[3] = 400
            self.triangle.points = self.triangle.points
'''

__all__ = ('Triangle', 'Quad', 'Rectangle', 'RoundedRectangle', 'BorderImage', 'Ellipse',
           'Line', 'Point', 'Mesh', 'GraphicException', 'Bezier', 'SmoothLine')


include "../include/config.pxi"
include "common.pxi"
include "memory.pxi"

from os import environ
from kivy.graphics.vbo cimport *
from kivy.graphics.vertex cimport *
from kivy.graphics.instructions cimport *
from kivy.graphics.cgl cimport *
from kivy.logger import Logger
from kivy.graphics.texture cimport Texture
from kivy.utils import platform

cdef int gles_limts = int(environ.get(
    'KIVY_GLES_LIMITS', int(platform not in ('win', 'macosx', 'linux'))))


class GraphicException(Exception):
    '''Exception raised when a graphics error is fired.
    '''

include "vertex_instructions_line.pxi"


cdef class Bezier(VertexInstruction):
    '''A 2d Bezier curve.

    .. versionadded:: 1.0.8

    :Parameters:
        `points`: list
            List of points in the format (x1, y1, x2, y2...)
        `segments`: int, defaults to 180
            Define how many segments are needed for drawing the curve.
            The drawing will be smoother if you have many segments.
        `loop`: bool, defaults to False
            Set the bezier curve to join the last point to the first.
        `dash_length`: int
            Length of a segment (if dashed), defaults to 1.
        `dash_offset`: int
            Distance between the end of a segment and the start of the
            next one, defaults to 0. Changing this makes it dashed.
    '''

    # TODO: refactoring:
    #
    #    a) find interface common to all splines (given control points and
    #    perhaps tangents, what's the position on the spline for parameter t),
    #
    #    b) make that a superclass Spline,
    #    c) create BezierSpline subclass that does the computation

    def __init__(self, **kwargs):
        VertexInstruction.__init__(self, **kwargs)
        v = kwargs.get('points')
        self.points = v if v is not None else [0, 0, 0, 0, 0, 0, 0, 0]
        self._segments = kwargs.get('segments') or 180
        self._loop = kwargs.get('loop') or False
        if self._loop:
            self.points.extend(self.points[:2])
        self._dash_length = kwargs.get('dash_length') or 1
        self._dash_offset = kwargs.get('dash_offset') or 0
        self.batch.set_mode('line_strip')

    cdef void build(self):
        cdef int x, i, j
        cdef float l
        cdef list T = self.points[:]
        cdef vertex_t *vertices = NULL
        cdef unsigned short *indices = NULL
        cdef float tex_x
        cdef char *buf = NULL
        cdef Texture texture = self.texture

        if self._dash_offset != 0:
            if texture is None or texture._width != \
                (self._dash_length + self._dash_offset) or \
                texture._height != 1:

                self.texture = texture = Texture.create(
                        size=(self._dash_length + self._dash_offset, 1))
                texture.wrap = 'repeat'

            # create a buffer to fill our texture
            buf = <char *>malloc(4 * (self._dash_length + self._dash_offset))
            memset(buf, 255, self._dash_length * 4)
            memset(buf + self._dash_length * 4, 0, self._dash_offset * 4)

            p_str = buf[:(self._dash_length + self._dash_offset) * 4]

            texture.blit_buffer(p_str, colorfmt='rgba', bufferfmt='ubyte')
            free(buf)

        elif texture is not None:
            self.texture = None

        vertices = <vertex_t *>malloc((self._segments + 1) * sizeof(vertex_t))
        if vertices == NULL:
            raise MemoryError('vertices')

        indices = <unsigned short *>malloc(
                (self._segments + 1) * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        tex_x = x = 0
        for x in range(self._segments):
            l = <float>(x / (1.0 * self._segments))
            # http://en.wikipedia.org/wiki/De_Casteljau%27s_algorithm
            # as the list is in the form of (x1, y1, x2, y2...) iteration is
            # done on each item and the current item (xn or yn) in the list is
            # replaced with a calculation of "xn + x(n+1) - xn" x(n+1) is
            # placed at n+2. each iteration makes the list one item shorter
            for i in range(1, len(T)):
                for j in range(len(T) - 2*i):
                    T[j] = T[j] + (T[j+2] - T[j]) * l

            # we got the coordinates of the point in T[0] and T[1]
            vertices[x].x = T[0]
            vertices[x].y = T[1]
            if self._dash_offset != 0 and x > 0:
                tex_x += <float>(sqrt(
                        pow(vertices[x].x - vertices[x-1].x, 2) +
                        pow(vertices[x].y - vertices[x-1].y, 2)) / (
                                self._dash_length + self._dash_offset))

                vertices[x].s0 = tex_x
                vertices[x].t0 = 0

            indices[x] = x

        # add one last point to join the curve to the end
        vertices[x+1].x = T[-2]
        vertices[x+1].y = T[-1]

        tex_x += <float>(sqrt(
                (vertices[x+1].x - vertices[x].x) ** 2 +
                (vertices[x+1].y - vertices[x].y) ** 2) / (
                        self._dash_length + self._dash_offset))

        vertices[x+1].s0 = tex_x
        vertices[x+1].t0 = 0
        indices[x+1] = x + 1

        self.batch.set_data(
                vertices,
                self._segments + 1,
                indices,
                self._segments + 1)

        free(vertices)
        free(indices)

    @property
    def points(self):
        '''Property for getting/settings the points of the triangle.

        .. warning::

            This will always reconstruct the whole graphic from the new points
            list. It can be very CPU intensive.
        '''
        return self._points

    @points.setter
    def points(self, points):
        self._points = list(points)
        if self._loop:
            self._points.extend(points[:2])
        self.flag_data_update()

    @property
    def segments(self):
        '''Property for getting/setting the number of segments of the curve.
        '''
        return self._segments

    @segments.setter
    def segments(self, value):
        if value <= 1:
            raise GraphicException('Invalid segments value, must be >= 2')
        self._segments = value
        self.flag_data_update()

    @property
    def dash_length(self):
        '''Property for getting/setting the length of the dashes in the curve.
        '''
        return self._dash_length


    @dash_length.setter
    def dash_length(self, value):
        if value < 0:
            raise GraphicException('Invalid dash_length value, must be >= 0')
        self._dash_length = value
        self.flag_data_update()

    @property
    def dash_offset(self):
        '''Property for getting/setting the offset between the dashes in the
        curve.
        '''
        return self._dash_offset


    @dash_offset.setter
    def dash_offset(self, value):
        if value < 0:
            raise GraphicException('Invalid dash_offset value, must be >= 0')
        self._dash_offset = value
        self.flag_data_update()


cdef class StripMesh(VertexInstruction):
    '''A specialized 2d mesh.

    (internal) Used for SVG, will be available with doc later.
    '''
    def __init__(self, VertexFormat fmt):
        cdef VBO vbo
        VertexInstruction.__init__(self)
        vbo = VBO(fmt)
        self.batch = VertexBatch(vbo=vbo)
        self.batch.set_mode("triangle_strip")
        self.icount = 0
        self.li = self.lic = 0

    cdef int add_triangle_strip(self, float *vertices, int vcount, int icount,
            int mode):
        cdef int i, li = self.li
        cdef int istart = 0
        cdef unsigned short *indices = NULL
        cdef vsize = self.batch.vbo.vertex_format.vsize

        if vcount == 0 or icount < 3:
            return 0
        if self.icount + icount > 65533:  # (optimization of) self.icount + icount - 2 > 65535
            return 0

        if self.icount > 0:
            # repeat the last indice and the first of the new batch
            istart = 2

        indices = <unsigned short *>malloc((icount + istart) * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        if istart == 2:
            indices[0] = self.lic
            indices[1] = li
        if mode == 0:
            # polygon
            for i in range(<int>int(icount / 2.)):
                indices[i * 2 + istart] = li + i
                indices[i * 2 + istart + 1] = li + (icount - i - 1)
            if icount % 2 == 1:
                indices[icount + istart - 1] = li + <unsigned short>int(icount / 2.)
        elif mode == 1:
            # line
            for i in range(icount):
                indices[istart + i] = li + i

        self.lic = indices[icount + istart - 1]

        self.batch.append_data(vertices, <int>(vcount / vsize), indices,
                <int>(icount + istart))

        free(indices)
        self.icount += icount + istart
        self.li += icount
        return 1


cdef class Mesh(VertexInstruction):
    '''A 2d mesh.

    In OpenGL ES 2.0 and in our graphics implementation, you cannot have more
    than 65535 indices.

    A list of vertices is described as::

        vertices = [x1, y1, u1, v1, x2, y2, u2, v2, ...]
                    |            |  |            |
                    +---- i1 ----+  +---- i2 ----+

    If you want to draw a triangle, add 3 vertices. You can then make an
    indices list as follows:

        indices = [0, 1, 2]

    .. versionadded:: 1.1.0

    :Parameters:
        `vertices`: iterable
            List of vertices in the format (x1, y1, u1, v1, x2, y2, u2, v2...).
        `indices`: iterable
            List of indices in the format (i1, i2, i3...).
        `mode`: str
            Mode of the vbo. Check :attr:`mode` for more information. Defaults to
            'points'.
        `fmt`: list
            The format for vertices, by default, each vertex is described by 2D
            coordinates (x, y) and 2D texture coordinate (u, v).
            Each element of the list should be a tuple or list, of the form

                (variable_name, size, type)

            which will allow mapping vertex data to the glsl instructions.

                [(b'v_pos', 2, 'float'), (b'v_tc', 2, 'float'),]

            will allow using

                attribute vec2 v_pos;
                attribute vec2 v_tc;

            in glsl's vertex shader.

    .. versionchanged:: 1.8.1
        Before, `vertices` and `indices` would always be converted to a list,
        now, they are only converted to a list if they do not implement the
        buffer interface. So e.g. numpy arrays, python arrays etc. are used
        in place, without creating any additional copies. However, the
        buffers cannot be readonly (even though they are not changed, due to
        a cython limitation) and must be contiguous in memory.

    .. note::
        When passing a memoryview or a instance that implements the buffer
        interface, `vertices` should be a buffer of floats (`'f'` code in
        python array) and `indices` should be a buffer of unsigned short (`'H'`
        code in python array). Arrays in other formats will still have to be
        converted internally, negating any potential gain.
    '''

    def __init__(self, **kwargs):
        cdef VBO vbo
        VertexInstruction.__init__(self, **kwargs)
        v = kwargs.get('vertices')
        self.vertices = v if v is not None else []
        v = kwargs.get('indices')
        self.indices = v if v is not None else []
        fmt = kwargs.get('fmt')
        if fmt is not None:
            if isinstance(fmt, VertexFormat):
                self.vertex_format = fmt
            else:
                self.vertex_format = VertexFormat(*fmt)
            vbo = VBO(self.vertex_format)
            self.batch = VertexBatch(vbo=vbo)
        self.mode = kwargs.get('mode') or 'points'
        self.is_built = 0

    cdef void build_triangle_fan(self, float *vertices, int vcount, int icount):
        cdef i
        cdef unsigned short *indices = NULL
        cdef vsize = self.batch.vbo.vertex_format.vsize

        if vcount == 0 or icount == 0:
            self.batch.clear_data()
            return

        indices = <unsigned short *>malloc(icount * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        for i in range(icount):
            indices[i] = i

        self.batch.set_data(vertices, <int>(vcount / vsize), indices,
                <int>icount)

        free(indices)
        self.is_built = 1

    cdef void build(self):
        if self.is_built:
            return
        cdef vsize = self.batch.vbo.vertex_format.vsize

        # if user updated the list, but didn't do self.indices = ... then
        # we'd not know about it, so ensure _indices/_indices is up to date
        if len(self._vertices) != self.vcount:
            self._vertices, self._fvertices = _ensure_float_view(self._vertices,
                &self._pvertices)
            self.vcount = <long>len(self._vertices)

        if len(self._indices) != self.icount:
            if len(self._indices) > 65535:
                raise GraphicException('Cannot upload more than 65535 indices'
                                       '(OpenGL ES 2 limitation)')
            self._indices, self._lindices = _ensure_ushort_view(self._indices,
                &self._pindices)
            self.icount = <long>len(self._indices)

        if self.vcount == 0 or self.icount == 0:
            self.batch.clear_data()
            return

        self.batch.set_data(&self._pvertices[0], <int>(self.vcount / vsize),
                            &self._pindices[0], <int>self.icount)

    @property
    def vertices(self):
        '''List of x, y, u, v coordinates used to construct the Mesh. Right now,
        the Mesh instruction doesn't allow you to change the format of the
        vertices, which means it's only x, y + one texture coordinate.
        '''
        return self._vertices

    @vertices.setter
    def vertices(self, value):
        self._vertices, self._fvertices = _ensure_float_view(value,
            &self._pvertices)
        self.vcount = <long>len(self._vertices)
        self.flag_data_update()

    @property
    def indices(self):
        '''Vertex indices used to specify the order when drawing the
        mesh.
        '''
        return self._indices

    @indices.setter
    def indices(self, value):
        if gles_limts and len(value) > 65535:
            raise GraphicException(
                'Cannot upload more than 65535 indices (OpenGL ES 2'
                ' limitation - consider setting KIVY_GLES_LIMITS)')
        self._indices, self._lindices = _ensure_ushort_view(value,
            &self._pindices)
        self.icount = <long>len(self._indices)
        self.flag_data_update()

    @property
    def mode(self):
        '''VBO Mode used for drawing vertices/indices. Can be one of 'points',
        'line_strip', 'line_loop', 'lines', 'triangles', 'triangle_strip' or
        'triangle_fan'.
        '''
        return self.batch.get_mode()

    @mode.setter
    def mode(self, mode):
        self.batch.set_mode(mode)



cdef class Point(VertexInstruction):
    '''A list of 2d points. Each point is represented as a square with a
    width/height of 2 times the :attr:`pointsize`.

    :Parameters:
        `points`: list
            List of points in the format (x1, y1, x2, y2...), where each pair
            of coordinates specifies the center of a new point.
        `pointsize`: float, defaults to 1.
            The size of the point, measured from the center to the edge. A
            value of 1.0 therefore means the real size will be 2.0 x 2.0.

    .. warning::

        Starting from version 1.0.7, vertex instruction have a limit of 65535
        vertices (indices of vertex to be accurate).
        2 entries in the list (x, y) will be converted to 4 vertices. So the
        limit inside Point() class is 2^15-2.

    '''
    cdef list _points
    cdef float _pointsize

    def __init__(self, **kwargs):
        VertexInstruction.__init__(self, **kwargs)
        v = kwargs.get('points')
        self.points = v if v is not None else []
        self.pointsize = kwargs.get('pointsize') or 1.

    cdef void build(self):
        cdef float x, y, ps = self._pointsize
        cdef int i, iv, ii, count = <int>(len(self._points) * 0.5)
        cdef list p = self.points
        cdef float *tc = self._tex_coords
        cdef vertex_t *vertices = NULL
        cdef unsigned short *indices = NULL

        #if there is no points...nothing to do
        if count < 1:
            self.batch.clear_data()
            return

        vertices = <vertex_t *>malloc(count * 4 * sizeof(vertex_t))
        if vertices == NULL:
            raise MemoryError('vertices')

        indices = <unsigned short *>malloc(count * 6 * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        for i in xrange(count):
            x = p[i * 2]
            y = p[i * 2 + 1]
            iv = i * 4
            vertices[iv].x = x - ps
            vertices[iv].y = y - ps
            vertices[iv].s0 = tc[0]
            vertices[iv].t0 = tc[1]
            vertices[iv + 1].x = x + ps
            vertices[iv + 1].y = y - ps
            vertices[iv + 1].s0 = tc[2]
            vertices[iv + 1].t0 = tc[3]
            vertices[iv + 2].x = x + ps
            vertices[iv + 2].y = y + ps
            vertices[iv + 2].s0 = tc[4]
            vertices[iv + 2].t0 = tc[5]
            vertices[iv + 3].x = x - ps
            vertices[iv + 3].y = y + ps
            vertices[iv + 3].s0 = tc[6]
            vertices[iv + 3].t0 = tc[7]

            ii = i * 6
            indices[ii] = iv
            indices[ii + 1] = iv + 1
            indices[ii + 2] = iv + 2
            indices[ii + 3] = iv + 2
            indices[ii + 4] = iv + 3
            indices[ii + 5] = iv

        self.batch.set_data(vertices, <int>(count * 4),
                            indices, <int>(count * 6))

        free(vertices)
        free(indices)

    def add_point(self, float x, float y):
        '''Add a point to the current :attr:`points` list.

        If you intend to add multiple points, prefer to use this method instead
        of reassigning a new :attr:`points` list. Assigning a new :attr:`points`
        list will recalculate and reupload the whole buffer into the GPU.
        If you use add_point, it will only upload the changes.
        '''
        cdef float ps = self._pointsize
        cdef int iv, count = <int>(len(self._points) * 0.5)
        cdef float *tc = self._tex_coords
        cdef vertex_t vertices[4]
        cdef unsigned short indices[6]

        if len(self._points) > 2**15 - 2:
            raise GraphicException('Cannot add elements (limit is 2^15-2)')

        self._points.append(x)
        self._points.append(y)

        vertices[0].x = x - ps
        vertices[0].y = y - ps
        vertices[0].s0 = tc[0]
        vertices[0].t0 = tc[1]
        vertices[1].x = x + ps
        vertices[1].y = y - ps
        vertices[1].s0 = tc[2]
        vertices[1].t0 = tc[3]
        vertices[2].x = x + ps
        vertices[2].y = y + ps
        vertices[2].s0 = tc[4]
        vertices[2].t0 = tc[5]
        vertices[3].x = x - ps
        vertices[3].y = y + ps
        vertices[3].s0 = tc[6]
        vertices[3].t0 = tc[7]

        iv = count * 4
        indices[0] = iv
        indices[1] = iv + 1
        indices[2] = iv + 2
        indices[3] = iv + 2
        indices[4] = iv + 3
        indices[5] = iv

        # append the vertices / indices to current vertex batch
        self.batch.append_data(vertices, 4, indices, 6)

        if self.parent is not None:
            self.parent.flag_data_update()

    @property
    def points(self):
        '''Property for getting/settings the center points in the points list.
        Each pair of coordinates specifies the center of a new point.
        '''
        return self._points

    @points.setter
    def points(self, points):
        if self._points == points:
            return
        cdef list _points = list(points)
        if len(_points) > 2**15-2:
            raise GraphicException('Too many elements (limit is 2^15-2)')
        self._points = list(points)
        self.flag_data_update()

    @property
    def pointsize(self):
        '''Property for getting/setting point size.
        The size is measured from the center to the edge, so a value of 1.0
        means the real size will be 2.0 x 2.0.
        '''
        return self._pointsize

    @pointsize.setter
    def pointsize(self, float pointsize):
        if self._pointsize == pointsize:
            return
        self._pointsize = pointsize
        self.flag_data_update()


cdef class Plus(VertexInstruction):
    '''A list of 2d points. Each point is represented as a plus sign
    with a width/height of 2 times the :attr: 'markersize'.

    :Parameters:
        `points`: list
            List of points in the format (x1, y1, x2, y2...), where each pair
            of coordinates specifies the center of a new plus.
        `pointsize`: float, defaults to 1.
            The size of the point, measured from the center to the edge. A
            value of 1.0 therefore means the real size will be 2.0 x 2.0.

    .. warning::

        Starting from version 1.0.7, vertex instruction have a limit of 65535
        vertices (indices of vertex to be accurate).
        2 entries in the list (x, y) will be converted to 4 vertices. So the
        limit inside Plus() class is 2^15-2.

    '''
    cdef list _points
    cdef float _pointsize

    def __init__(self, **kwargs):
        VertexInstruction.__init__(self, **kwargs)
        v = kwargs.get('points')
        self.points = v if v is not None else []
        self.pointsize = kwargs.get('pointsize') or 1.

    cdef void build(self):
        cdef float x, y, ps = self._pointsize
        cdef float ips = ps / 4  # Inner Point Size (ips)
        cdef int i, iv, ii, count = <int>(len(self._points) * 0.5)
        cdef list p = self.points
        cdef float *tc = self._tex_coords
        cdef vertex_t *vertices = NULL
        cdef unsigned short *indices = NULL

        #if there is no points...nothing to do
        if count < 1:
            self.batch.clear_data()
            return

        vertices = <vertex_t *>malloc(count * 12 * sizeof(vertex_t))
        if vertices == NULL:
            raise MemoryError('vertices')

        indices = <unsigned short *>malloc(count * 14 * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        for i in xrange(count):
            x = p[i * 2]
            y = p[i * 2 + 1]
            iv = i * 4
            vertices[iv].x = x - ps
            vertices[iv].y = y - ips
            vertices[iv].s0 = tc[0]
            vertices[iv].t0 = tc[1]
            vertices[iv + 1].x = x - ips
            vertices[iv + 1].y = y - ips
            vertices[iv + 1].s0 = tc[2]
            vertices[iv + 1].t0 = tc[3]
            vertices[iv + 2].x = x - ips
            vertices[iv + 2].y = y - ps
            vertices[iv + 2].s0 = tc[4]
            vertices[iv + 2].t0 = tc[5]
            vertices[iv + 3].x = x + ips
            vertices[iv + 3].y = y - ps
            vertices[iv + 3].s0 = tc[6]
            vertices[iv + 3].t0 = tc[7]
            vertices[iv + 4].x = x + ips
            vertices[iv + 4].y = y - ips
            vertices[iv + 4].s0 = tc[8]
            vertices[iv + 4].t0 = tc[9]
            vertices[iv + 5].x = x + ps
            vertices[iv + 5].y = y - ips
            vertices[iv + 5].s0 = tc[10]
            vertices[iv + 5].t0 = tc[11]
            vertices[iv + 6].x = x + ps
            vertices[iv + 6].y = y + ips
            vertices[iv + 6].s0 = tc[12]
            vertices[iv + 6].t0 = tc[13]
            vertices[iv + 7].x = x + ips
            vertices[iv + 7].y = y + ips
            vertices[iv + 7].s0 = tc[14]
            vertices[iv + 7].t0 = tc[15]
            vertices[iv + 8].x = x + ips
            vertices[iv + 8].y = y + ps
            vertices[iv + 8].s0 = tc[16]
            vertices[iv + 8].t0 = tc[17]
            vertices[iv + 9].x = x - ips
            vertices[iv + 9].y = y + ps
            vertices[iv + 9].s0 = tc[18]
            vertices[iv + 9].t0 = tc[19]
            vertices[iv + 10].x = x - ips
            vertices[iv + 10].y = y + ips
            vertices[iv + 10].s0 = tc[20]
            vertices[iv + 10].t0 = tc[21]
            vertices[iv + 11].x = x - ps
            vertices[iv + 11].y = y + ips
            vertices[iv + 11].s0 = tc[22]
            vertices[iv + 11].t0 = tc[23]

            ii = i * 6
            indices[ii] = iv
            indices[ii + 1] = iv + 1
            indices[ii + 2] = iv + 2
            indices[ii + 3] = iv + 2
            indices[ii + 4] = iv + 3
            indices[ii + 5] = iv + 4
            indices[ii + 6] = iv + 5
            indices[ii + 7] = iv + 6
            indices[ii + 8] = iv + 7
            indices[ii + 9] = iv + 8
            indices[ii + 10] = iv + 9
            indices[ii + 11] = iv + 10
            indices[ii + 12] = iv + 11
            indices[ii + 13] = iv

        self.batch.set_data(vertices, <int>(count * 4),
                            indices, <int>(count * 6))

        free(vertices)
        free(indices)


    def add_plus(self, float x, float y):
        '''Add a point to the current :attr:`points` list.

        If you intend to add multiple points, prefer to use this method instead
        of reassigning a new :attr:`points` list. Assigning a new :attr:`points`
        list will recalculate and reupload the whole buffer into the GPU.
        If you use add_plus, it will only upload the changes.
        '''
        cdef float ps = self._pointsize
        cdef float ips = ps/4
        cdef int iv, count = <int>(len(self._points) * 0.5)
        cdef float *tc = self._tex_coords
        cdef vertex_t vertices[12]
        cdef unsigned short indices[14]

        if len(self._points) > 2**15 - 2:
            raise GraphicException('Cannot add elements (limit is 2^15-2)')

        self._points.append(x)
        self._points.append(y)

        vertices[0].x = x - ps
        vertices[0].y = y - ips
        vertices[0].s0 = tc[0]
        vertices[0].t0 = tc[1]
        vertices[1].x = x - ips
        vertices[1].y = y - ips
        vertices[1].s0 = tc[2]
        vertices[1].t0 = tc[3]
        vertices[2].x = x - ips
        vertices[2].y = y - ps
        vertices[2].s0 = tc[4]
        vertices[2].t0 = tc[5]
        vertices[3].x = x + ips
        vertices[3].y = y - ps
        vertices[3].s0 = tc[6]
        vertices[3].t0 = tc[7]
        vertices[4].x = x + ips
        vertices[4].y = y - ips
        vertices[4].s0 = tc[8]
        vertices[4].t0 = tc[9]
        vertices[5].x = x + ps
        vertices[5].y = y - ips
        vertices[5].s0 = tc[10]
        vertices[5].t0 = tc[11]
        vertices[6].x = x + ps
        vertices[6].y = y + ips
        vertices[6].s0 = tc[12]
        vertices[6].t0 = tc[13]
        vertices[7].x = x + ips
        vertices[7].y = y + ips
        vertices[7].s0 = tc[14]
        vertices[7].t0 = tc[15]
        vertices[8].x = x + ips
        vertices[8].y = y + ps
        vertices[8].s0 = tc[16]
        vertices[8].t0 = tc[17]
        vertices[9].x = x - ips
        vertices[9].y = y + ps
        vertices[9].s0 = tc[18]
        vertices[9].t0 = tc[19]
        vertices[10].x = x - ips
        vertices[10].y = y + ips
        vertices[10].s0 = tc[20]
        vertices[10].t0 = tc[21]
        vertices[11].x = x - ps
        vertices[11].y = y + ips
        vertices[11].s0 = tc[22]
        vertices[11].t0 = tc[23]

        iv = count * 4
        indices[0] = iv
        indices[1] = iv + 1
        indices[2] = iv + 2
        indices[3] = iv + 2
        indices[4] = iv + 3
        indices[5] = iv + 4
        indices[6] = iv + 5
        indices[7] = iv + 6
        indices[8] = iv + 7
        indices[9] = iv + 8
        indices[10] = iv + 9
        indices[11] = iv + 10
        indices[12] = iv + 11
        indices[13] = iv

        # append the vertices / indices to current vertex batch
        self.batch.append_data(vertices, 12, indices, 14)

        if self.parent is not None:
            self.parent.flag_data_update()

    @property
    def points(self):
        '''Property for getting/settings the center points in the points list.
        Each pair of coordinates specifies the center of a new point.
        '''
        return self._points

    @points.setter
    def points(self, points):
        if self._points == points:
            return
        cdef list _points = list(points)
        if len(_points) > 2**15-2:
            raise GraphicException('Too many elements (limit is 2^15-2)')
        self._points = list(points)
        self.flag_data_update()

    @property
    def pointsize(self):
        '''Property for getting/setting point size.
        The size is measured from the center to the edge, so a value of 1.0
        means the real size will be 2.0 x 2.0.
        '''
        return self._pointsize

    @pointsize.setter
    def pointsize(self, float pointsize):
        if self._pointsize == pointsize:
            return
        self._pointsize = pointsize
        self.flag_data_update()


cdef class Triangle(VertexInstruction):
    '''A 2d triangle.

    :Parameters:
        `points`: list
            List of points in the format (x1, y1, x2, y2, x3, y3).
    '''

    cdef list _points

    def __init__(self, **kwargs):
        VertexInstruction.__init__(self, **kwargs)
        v = kwargs.get('points')
        self.points = v if v is not None else (0.0,0.0, 100.0,0.0, 50.0,100.0)

    cdef void build(self):
        cdef list vc
        cdef float *tc
        cdef vertex_t vertices[3]
        cdef unsigned short *indices = [0, 1, 2]

        vc = self.points;
        tc = self._tex_coords

        vertices[0].x = vc[0]
        vertices[0].y = vc[1]
        vertices[0].s0 = tc[0]
        vertices[0].t0 = tc[1]
        vertices[1].x = vc[2]
        vertices[1].y = vc[3]
        vertices[1].s0 = tc[2]
        vertices[1].t0 = tc[3]
        vertices[2].x = vc[4]
        vertices[2].y = vc[5]
        vertices[2].s0 = tc[4]
        vertices[2].t0 = tc[5]

        self.batch.set_data(vertices, 3, indices, 3)

    @property
    def points(self):
        '''Property for getting/settings points of the triangle.
        '''
        return self._points

    @points.setter
    def points(self, points):
        self._points = list(points)
        self.flag_data_update()


cdef class Quad(VertexInstruction):
    '''A 2d quad.

    :Parameters:
        `points`: list
            List of point in the format (x1, y1, x2, y2, x3, y3, x4, y4).
    '''
    cdef list _points

    def __init__(self, **kwargs):
        VertexInstruction.__init__(self, **kwargs)
        v = kwargs.get('points')
        self.points = v if v is not None else \
               (  0.0,  50.0,   50.0,   0.0,
                100.0,  50.0,   50.0, 100.0 )

    cdef void build(self):
        cdef list vc
        cdef float *tc
        cdef vertex_t vertices[4]
        cdef unsigned short *indices = [0, 1, 2, 2, 3, 0]

        vc = self.points
        tc = self._tex_coords

        vertices[0].x = vc[0]
        vertices[0].y = vc[1]
        vertices[0].s0 = tc[0]
        vertices[0].t0 = tc[1]
        vertices[1].x = vc[2]
        vertices[1].y = vc[3]
        vertices[1].s0 = tc[2]
        vertices[1].t0 = tc[3]
        vertices[2].x = vc[4]
        vertices[2].y = vc[5]
        vertices[2].s0 = tc[4]
        vertices[2].t0 = tc[5]
        vertices[3].x = vc[6]
        vertices[3].y = vc[7]
        vertices[3].s0 = tc[6]
        vertices[3].t0 = tc[7]

        self.batch.set_data(vertices, 4, indices, 6)

    @property
    def points(self):
        '''Property for getting/settings points of the quad.
        '''
        return self._points

    @points.setter
    def points(self, points):
        self._points = list(points)
        if len(self._points) != 8:
            raise GraphicException(
                'Quad: invalid number of points (%d instead of 8)' % len(
                self._points))
        self.flag_data_update()


cdef class Rectangle(VertexInstruction):
    '''A 2d rectangle.

    :Parameters:
        `pos`: list
            Position of the rectangle, in the format (x, y).
        `size`: list
            Size of the rectangle, in the format (width, height).
    '''
    cdef float x,y,w,h
    cdef list _points

    def __init__(self, **kwargs):
        VertexInstruction.__init__(self, **kwargs)
        v = kwargs.get('pos')
        self.pos = v if v is not None else (0, 0)
        v = kwargs.get('size')
        self.size = v if v is not None else (100, 100)

    cdef void build(self):
        cdef float x, y, w, h
        cdef float *tc = self._tex_coords
        cdef vertex_t vertices[4]
        cdef unsigned short *indices = [0, 1, 2, 2, 3, 0]

        # reset points
        self._points = []

        x, y = self.x, self.y
        w, h = self.w, self.h


        vertices[0].x = x
        vertices[0].y = y
        vertices[0].s0 = tc[0]
        vertices[0].t0 = tc[1]
        vertices[1].x = x + w
        vertices[1].y = y
        vertices[1].s0 = tc[2]
        vertices[1].t0 = tc[3]
        vertices[2].x = x + w
        vertices[2].y = y + h
        vertices[2].s0 = tc[4]
        vertices[2].t0 = tc[5]
        vertices[3].x = x
        vertices[3].y = y + h
        vertices[3].s0 = tc[6]
        vertices[3].t0 = tc[7]

        self._points = [x, y, x + w, y, x + w, y + h, x, y + h]

        self.batch.set_data(vertices, 4, indices, 6)

    @property
    def pos(self):
        '''Property for getting/settings the position of the rectangle.
        '''
        return (self.x, self.y)

    @pos.setter
    def pos(self, pos):
        cdef float x, y
        x, y = pos
        if self.x == x and self.y == y:
            return
        self.x = x
        self.y = y
        self.flag_data_update()

    @property
    def size(self):
        '''Property for getting/settings the size of the rectangle.
        '''
        return (self.w, self.h)

    @size.setter
    def size(self, size):
        cdef float w, h
        w, h = size
        if self.w == w and self.h == h:
            return
        self.w = w
        self.h = h
        self.flag_data_update()

    @property
    def points(self):
        '''Property for getting the points used to draw the vertices.

        .. versionadded:: 2.3.0

        '''
        return self._points



cdef class BorderImage(Rectangle):
    '''A 2d border image. The behavior of the border image is similar to the
    concept of a CSS3 border-image.

    :Parameters:
        `border`: list
            Border information in the format (bottom, right, top, left).
            Each value is in pixels.

        `auto_scale`: string
            .. versionadded:: 1.9.1

            .. versionchanged:: 1.9.2

                This used to be a bool and has been changed to be a string
                state.

            Can be one of 'off', 'both', 'x_only', 'y_only', 'y_full_x_lower',
            'x_full_y_lower', 'both_lower'.

            Autoscale controls the behavior of the 9-slice.

            By default the border values are preserved exactly, meaning that
            if the total size of the object is smaller than the border values
            you will have some 'rendering errors' where your texture appears
            inside out. This also makes it impossible to achieve a rounded
            button that scales larger than the size of its source texture. The
            various options for auto_scale will let you achieve some mixes of
            the 2 types of rendering.

            'off': is the default and behaves as BorderImage did when auto_scale
            was False before.

            'both': Scales both x and y dimension borders according to the size
            of the BorderImage, this disables the BorderImage making it render
            the same as a regular Image.

            'x_only': The Y dimension functions as the default, and the X
            scales to the size of the BorderImage's width.

            'y_only': The X dimension functions as the default, and the Y
            scales to the size of the BorderImage's height.

            'y_full_x_lower': Y scales as in 'y_only', Y scales if the
            size of the scaled version would be smaller than the provided
            border only.

            'x_full_y_lower': X scales as in 'x_only', Y scales if the
            size of the scaled version would be smaller than the provided
            border only.

            'both_lower': This is what auto_scale did when it was True in 1.9.1
            Both X and Y dimensions will be scaled if the BorderImage is
            smaller than the source.

            If the BorderImage's size is less than the sum of its
            borders, horizontally or vertically, and this property is
            set to True, the borders will be rescaled to accommodate for
            the smaller size.

    '''
    cdef list _border
    cdef list _display_border
    cdef str _auto_scale

    def __init__(self, **kwargs):
        Rectangle.__init__(self, **kwargs)
        v = kwargs.get('border')
        self.border = v if v is not None else (10, 10, 10, 10)
        self.auto_scale = kwargs.get('auto_scale', 'off')
        self.display_border = kwargs.get('display_border', [])

    cdef void build(self):
        if not self.texture:
            Logger.trace('GBorderImage: texture missing')
            return

        # pos and size of border rectangle
        cdef float x, y, w, h
        x = self.x
        y = self.y
        w = self.w
        h = self.h

        # width and height of texture in pixels, and tex coord space
        cdef float tw, th, tcw, tch
        cdef float *tc = self._tex_coords
        cdef float tc0, tc1, tc2, tc7
        tc0 = tc[0]
        tc1 = tc[1]
        tc2 = tc[2]
        tc7 = tc[7]
        tw, th  = self.texture.size
        tcw = tc2 - tc0  #right - left
        tch = tc7 - tc1  #top - bottom

        # calculate border offset in texture coord space
        # border width(px)/texture width(px) *  tcoord width
        cdef list b = self._border
        cdef float b0, b1, b2, b3
        cdef float tb[4] # border offset in texture coordinate space
        b0, b1, b2, b3 = b
        tb[0] = b0 / th * tch
        tb[1] = b1 / tw * tcw
        tb[2] = b2 / th * tch
        tb[3] = b3 / tw * tcw

        cdef float sb0, sb1, sb2, sb3

        if self._auto_scale == 'off':
            sb0, sb1, sb2, sb3 = b0, b1, b2, b3
        elif self._auto_scale == 'both':
            sb0 = (b0/th) * h
            sb1 = (b1/tw) * w
            sb2 = (b2/th) * h
            sb3 = (b3/tw) * w
        elif self._auto_scale == 'x_only':
            sb0 = b0
            sb1 = (b1/tw) * w
            sb2 = b2
            sb3 = (b3/tw) * w
        elif self._auto_scale == 'y_only':
            sb0 = (b0/th) * h
            sb1 = b1
            sb2 = (b2/th) * h
            sb3 = b3
        elif self._auto_scale == 'y_full_x_lower':
            sb0 = (b0/th) * h
            sb1 = min((b1/tw) * w, b1)
            sb2 = (b2/th) * h
            sb3 = min((b3/tw) * w, b3)
        elif self._auto_scale == 'x_full_y_lower':
            sb0 = min((b0/th) * h, b0)
            sb1 = (b1/tw) * w
            sb2 = min((b2/th) * h, b2)
            sb3 = (b3/tw) * w
        elif self._auto_scale == 'both_lower':
            sb0 = min((b0/th) * h, b0)
            sb1 = min((b1/tw) * w, b1)
            sb2 = min((b2/th) * h, b2)
            sb3 = min((b3/tw) * w, b3)
        else:
            sb0, sb1, sb2, sb3 = b0, b1, b2, b3

        # horizontal and vertical sections
        cdef float hs[4]
        cdef float vs[4]
        cdef list db = self._display_border
        if db:
            sb0, sb1, sb2, sb3 = db
        hs[0] = x;            vs[0] = y
        hs[1] = x + sb3;       vs[1] = y + sb0
        hs[2] = x + w - sb1;   vs[2] = y + h - sb2
        hs[3] = x + w;        vs[3] = y + h

        cdef float ths[4]
        cdef float tvs[4]
        ths[0] = tc0;              tvs[0] = tc1
        ths[1] = tc0 + tb[3];      tvs[1] = tc1 + tb[0]
        ths[2] = tc0 + tcw-tb[1];  tvs[2] = tc1 + tch - tb[2]
        ths[3] = tc0 + tcw;        tvs[3] = tc1 + tch

        '''
            v9---v8------v7----v6
            |        b2        |
           v10  v15------v14   v5
            |    |        |    |
            |-b4-|        |-b1-|
            |    |        |    |
           v11  v12------v13   v4
            |        b0        |
            v0---v1------v2----v3
        '''

        # set the vertex data
        # WARNING we are allocating the vertices as a float
        # because we know exactly the format.
        assert sizeof(vertex_t) == 4 * sizeof(float)
        cdef float *vertices = [
            hs[0], vs[0], ths[0], tvs[0], #v0
            hs[1], vs[0], ths[1], tvs[0], #v1
            hs[2], vs[0], ths[2], tvs[0], #v2
            hs[3], vs[0], ths[3], tvs[0], #v3
            hs[3], vs[1], ths[3], tvs[1], #v4
            hs[3], vs[2], ths[3], tvs[2], #v5
            hs[3], vs[3], ths[3], tvs[3], #v6
            hs[2], vs[3], ths[2], tvs[3], #v7
            hs[1], vs[3], ths[1], tvs[3], #v8
            hs[0], vs[3], ths[0], tvs[3], #v9
            hs[0], vs[2], ths[0], tvs[2], #v10
            hs[0], vs[1], ths[0], tvs[1], #v11
            hs[1], vs[1], ths[1], tvs[1], #v12
            hs[2], vs[1], ths[2], tvs[1], #v13
            hs[2], vs[2], ths[2], tvs[2], #v14
            hs[1], vs[2], ths[1], tvs[2]] #v15

        cdef unsigned short *indices = [
             0,  1, 12,    12, 11,  0,  # bottom left
             1,  2, 13,    13, 12,  1,  # bottom middle
             2,  3,  4,     4, 13,  2,  # bottom right
            13,  4,  5,     5, 14, 13,  # center right
            14,  5,  6,     6,  7, 14,  # top right
            15, 14,  7,     7,  8, 15,  # top middle
            10, 15,  8,     8,  9, 10,  # top left
            11, 12, 15,    15, 10, 11,  # center left
            12, 13, 14,    14, 15, 12]  # center middle

        self.batch.set_data(<vertex_t *>vertices, 16, indices, 54)


    @property
    def border(self):
        '''Property for getting/setting the border of the class.
        '''
        return self._border

    @border.setter
    def border(self, b):
        self._border = list(b)
        self.flag_data_update()

    @property
    def auto_scale(self):
        '''Property for setting if the corners are automatically scaled
        when the BorderImage is too small.
        '''
        return self._auto_scale


    @auto_scale.setter
    def auto_scale(self, str value):
        self._auto_scale = value
        self.flag_data_update()

    @property
    def display_border(self):
        '''Property for getting/setting the border display size.
        '''
        return self._display_border

    @display_border.setter
    def display_border(self, b):
        self._display_border = list(b)
        self.flag_data_update()

cdef class Ellipse(Rectangle):
    '''A 2D ellipse.

    :Parameters:
        `segments`: int, the default value is calculated from the range between angle.
            Define how many segments are needed for drawing the ellipse.
            The ellipse drawing will be smoother if you have many segments,
            however you can also use this property to create polygons with 3 or more sides.
        `angle_start`: float, defaults to 0.0
            Specifies the starting angle, in degrees, of the disk portion.
        `angle_end`: float, defaults to 360.0
            Specifies the ending angle, in degrees, of the disk portion.

    .. versionchanged:: 1.0.7
        Added angle_start and angle_end.
    
    .. versionchanged:: 2.2.0
        The default number of segments is no longer 180, it is now calculated
        according to the angle range, as this is a more efficient approach.

    '''
    cdef int _segments
    cdef float _angle_start
    cdef float _angle_end

    def __init__(self, *args, **kwargs):
        Rectangle.__init__(self, **kwargs)
        self._segments = kwargs.get('segments') or 0
        self._angle_start = kwargs.get('angle_start') or 0.0
        self._angle_end = kwargs.get('angle_end') or 360.0

    cdef void build(self):
        cdef float *tc = self._tex_coords
        cdef int i, angle_dir
        cdef double angle_start, angle_end, angle_range
        cdef double x, y, angle, rx, ry, ttx, tty, tx, ty, tw, th
        cdef double cx, cy, tangential_factor, radial_factor, fx, fy
        cdef vertex_t *vertices = NULL
        cdef unsigned short *indices = NULL
        cdef int segments = self._segments
        cdef int vertices_count
        cdef bint use_first_vertex_as_last = False

        # reset points
        self._points = []

        if self.w == 0 or self.h == 0:
            return


        if segments == 0 or segments < 3:
            if segments != 0:
                Logger.warning('Ellipse: A minimum of 3 segments is required. The default value will be used instead.')
            segments = max(1, int(abs(self._angle_end - self._angle_start) / 2))

        tx = tc[0]
        ty = tc[1]
        tw = tc[4] - tx
        th = tc[5] - ty
        angle = 0.0
        rx = 0.5 * self.w
        ry = 0.5 * self.h

        if (
            abs(self._angle_start - self._angle_end) == 360
            or self._angle_start == self._angle_end
        ):
            use_first_vertex_as_last = True

        if use_first_vertex_as_last:
            vertices_count = segments + 1
        else:
            vertices_count = segments + 2

        vertices = <vertex_t *>malloc(vertices_count * sizeof(vertex_t))
        if vertices == NULL:
            raise MemoryError('vertices')

        indices = <unsigned short *>malloc((segments * 3) * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        # calculate the start/end angle in radians, and adapt the range
        if self._angle_end > self._angle_start:
            angle_dir = 1
        else:
            angle_dir = -1

        # rad = deg * (pi / 180), where pi / 180 = 0.0174...
        angle_start = self._angle_start * 0.017453292519943295
        angle_end = self._angle_end * 0.017453292519943295
        angle_range = -1 * (angle_end - angle_start) / segments

        # add start vertex in the middle
        x = self.x + rx
        y = self.y + ry
        ttx = ((x - self.x) / self.w) * tw + tx
        tty = ((y - self.y) / self.h) * th + ty

        vertices[vertices_count - 1].x = <float>x
        vertices[vertices_count - 1].y = <float>y
        vertices[vertices_count - 1].s0 = <float>ttx
        vertices[vertices_count - 1].t0 = <float>tty

        # super fast ellipse drawing
        # credit goes to: http://slabode.exofire.net/circle_draw.shtml
        tangential_factor = tan(angle_range)
        radial_factor = cos(angle_range)

        # Calculate the coordinates for a circle with radius 0.5 about
        # the point (0.5, 0.5). Only stretch to an ellipse later.
        cx = 0.5
        cy = 0.5
        r = 0.5
        x = r * sin(angle_start)
        y = r * cos(angle_start)

        for i in range(0, vertices_count - 1):
            ttx = (cx + x) * tw + tx
            tty = (cy + y) * th + ty
            real_x = self.x + (cx + x) * self.w
            real_y = self.y + (cy + y) * self.h
            vertices[i].x = <float>real_x
            vertices[i].y = <float>real_y
            vertices[i].s0 = <float>ttx
            vertices[i].t0 = <float>tty

            fx = -y
            fy = x
            x += fx * tangential_factor
            y += fy * tangential_factor
            x *= radial_factor
            y *= radial_factor

            self._points.extend([real_x, real_y])

        for i in range(0, segments * 3, 3):
            indices[i] = vertices_count - 1
            indices[i + 1] = i // 3
            indices[i + 2] = i // 3 + 1

        if use_first_vertex_as_last:
            indices[(segments * 3) - 1] = 0
            self._points.extend([vertices[0].x, vertices[0].y])

        self.batch.set_data(vertices, vertices_count, indices, segments * 3)

        free(vertices)
        free(indices)

    @property
    def segments(self):
        '''Property for getting/setting the number of segments of the ellipse.
        The ellipse drawing will be smoother if you have many segments, however
        you can also use this property to create polygons with 3 or more sides.
        Values smaller than 3 will not be represented and the number of
        segments will be automatically calculated.
        
        .. versionchanged:: 2.2.0
            The minimum number of segments allowed is 3. Smaller values will be
            ignored and the number of segments will be automatically calculated.
        '''
        
        return self._segments

    @segments.setter
    def segments(self, value):
        self._segments = value
        self.flag_data_update()

    @property
    def angle_start(self):
        '''Start angle of the ellipse in degrees, defaults to 0.
        '''
        return self._angle_start

    @angle_start.setter
    def angle_start(self, value):
        self._angle_start = value
        self.flag_data_update()

    @property
    def angle_end(self):
        '''End angle of the ellipse in degrees, defaults to 360.
        '''
        return self._angle_end

    @angle_end.setter
    def angle_end(self, value):
        self._angle_end = value
        self.flag_data_update()


cdef class RoundedRectangle(Rectangle):
    '''A 2D rounded rectangle.

    .. versionadded:: 1.9.1

    :Parameters:
        `segments`: int, defaults to 10
            Define how many segments are needed for drawing the rounded corner.
            The drawing will be smoother if you have many segments.
        `radius`: list, defaults to [(10.0, 10.0), (10.0, 10.0), (10.0, 10.0), (10.0, 10.0)]
            Specifies the radii used for the rounded corners clockwise:
            top-left, top-right, bottom-right, bottom-left.
            Elements of the list can be numbers or tuples of two numbers to specify different x,y dimensions.
            One value will define all corner radii to be of this value.
            Four values will define each corner radius separately.
            Higher numbers of values will be truncated to four.
            The first value will be used for all corners if there are fewer than four values.
    '''

    cdef object _segments  # number of segments for each corner
    cdef list _radius

    def __init__(self, **kwargs):
        Rectangle.__init__(self, **kwargs)
        self.batch.set_mode('triangle_fan')

        # number of segments for each corner
        segments = kwargs.get('segments', 10)  # allow 0 segments
        self._segments = self._check_segments(segments)

        radius = kwargs.get('radius') or [10.0]
        self._radius = self._check_radius(radius)
        self._points = []

    cdef object _check_segments(self, object segments):
        """
        Check segments argument, return list of four numeric values
        for each corner.
        """
        cdef list result = []

        # can be single numeric value
        if isinstance(segments, int):  # can't be float number
            return [segments] * 4

        # can be list of four values for each corner
        if isinstance(segments, list):
            result = [value for value in segments if isinstance(value, int)]

            if not result:
                raise GraphicException("Invalid segments value, must be list of integers")

            # set all values to first if less than four values
            if len(result) < 4:
                return result[:1] * 4
            else:
                return result[:4]

        else:
            raise GraphicException("Invalid segments value, must be integer or list of integers")

    cdef object _check_radius(self, object radius):
        """
        Check radius argument, return list of four tuples
        (xradius, yradius) for each corner.
        """
        cdef:
            list result = []
            object value

        for value in radius:
            if isinstance(value, tuple):
                # tuple: (a,) -> (a,a); (a,b)
                # extend/trim to exactly two coordinates
                if len(value) < 2:
                    value = value[:1] * 2
                result.append(value[:2])

            elif isinstance(value, (int, float)):
                # int/float: a -> (a,a)
                result.append((value, value))

            # some strange type came - skip it. next value will be used or radii will be set to first
            else:
                Logger.trace("GRoundedRectangle: '{}' object can\'t be used to specify radius. "
                             "Skipping...".format(radius.__class__.__name__))

        if not result:
            raise GraphicException("Invalid radius value, must be list of tuples/numerics")

        # set all radii to first if there aren't four of them
        if len(result) < 4:
            return result[:1] * 4
        else:
            return result[:4]

    cdef void build(self):
        cdef:
            float *tc = self._tex_coords
            vertex_t *vertices = NULL
            unsigned short *indices = NULL

            int count, corner, segments, dw, dh, index
            list xradius, yradius
            double rx, ry, half_w, half_h, angle
            double tx, ty, tw, th, px, py, x, y

        # reset points
        self._points = []

        # zero size of the figure
        if self.w == 0 or self.h == 0:
            return


        # 1 vertex for sharp corner (if segments or radius is zero)
        # `segments+1` vertices for round corner
        # plus 1 vertex for middle point
        count = sum([1 + segments * bool(rx * ry)
                     for (rx, ry), segments
                     in zip(self._radius, self._segments)]) + 1

        vertices = <vertex_t *>malloc((count) * sizeof(vertex_t))
        if vertices == NULL:
            raise MemoryError('vertices')

        # +1 because the last index must be the index of the first corner to close the fan
        indices = <unsigned short *>malloc((count + 1) * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        # half sizes
        half_w = self.w / 2
        half_h = self.h / 2

        # split radii by coordinate and make them <= half_size
        xradius = [min(r[0], half_w) for r in self._radius]
        yradius = [min(r[1], half_h) for r in self._radius]

        # texture coordinates
        tx = tc[0]
        ty = tc[1]
        tw = tc[4] - tx
        th = tc[5] - ty

        # add start vertex in the middle of the figure
        vertices[0].x = <float>(self.x + half_w)
        vertices[0].y = <float>(self.y + half_h)
        vertices[0].s0 = <float>(tx + tw / 2)
        vertices[0].t0 = <float>(ty + th / 2)
        indices[0] = 0

        index = 1  # vertex index from 1 to count
        for corner in range(4):
            # start angle for the corner. end is 90 degrees lesser (clockwise)
            angle = 180 - 90 * corner

            # coefficients to enable/disable multiplication by width/height
            dw, dh = [(0,1), (1,1), (1,0), (0,0)][corner]

            # ellipse dimensions
            rx, ry = xradius[corner], yradius[corner]

            # ellipse center coordinates
            px, py = [
                # top left
                (self.x + rx,
                 self.y + self.h - ry),

                # top right
                (self.x + self.w - rx,
                 self.y + self.h - ry),

                # bottom right
                (self.x + self.w - rx,
                 self.y + ry),

                # bottom left
                (self.x + rx,
                 self.y + ry)
            ][corner]

            # number of segments for this corner
            segments = self._segments[corner]

            # if at least one radius is zero or no segments
            if not(rx and ry and segments):
                # sharp corner
                vertices[index].x = self.x + self.w * dw
                vertices[index].y = self.y + self.h * dh
                vertices[index].s0 = <float>(tx + tw * dw)
                vertices[index].t0 = <float>(ty + th * dh)

                self._points.append((self.x + self.w * dw, self.y + self.h * dh))

            else:
                # round corner
                points = self.draw_arc(px, py, rx, ry, angle, angle - 90, segments)
                for i, point in enumerate(points, index):
                    x, y = point
                    vertices[i].x = <float>x
                    vertices[i].y = <float>y
                    vertices[i].s0 = <float>((x - self.x) / self.w)
                    vertices[i].t0 = <float>(1 - (y - self.y) / self.h)  # flip vertically
                    indices[i] = i
                index += segments

                # Add final vertex that closes the arc, explained below
                x = px * (dw != dh) + self.x * (dw == dh) + self.w * (dw * dh)
                y = py * (dw == dh) + self.y * (dw != dh) + self.h * (dh > dw)
                vertices[index].x = <float>x
                vertices[index].y = <float>y
                vertices[index].s0 = <float>((x - self.x) / self.w)
                vertices[index].t0 = <float>(1 - (y - self.y) / self.h)  # flip vertically

                self._points.extend(points)
                self._points.append((x, y))

                '''
                We have defined these coefficients for arcs:
                   tl tr br bl
                dw: 0  1  1  0;
                dh: 1  1  0  0;

                Let's not define multiple arrays of coefficients, but
                use `dw` and `dh` to calculate coordinates for closing vertices

                Formula looks like this:

                x = px * A + self.x * B + self.w * C
                y = py * D + self.y * E + self.h * F

                , where A - F are boolean values.

                For correct coordinates, coefficients should have these values:

                  tl tr br bl
                A: 1  0  1  0; when `dw` != `dh`
                B: 0  1  0  1; when `dw` == `dh`
                C: 0  1  0  0; when `dw` and `dh` are both `1`

                  tl tr br bl
                D: 0  1  0  1; same as B
                E: 1  0  1  0; same as A
                F: 1  0  0  0; when `dh` > `dw`

                NOTE: Closing vertex will duplicate next opening vertex,
                      when corner radius is equal to half_size.
                      (e.g: a circle will have 4 duplicates)
                      Without it, however, figure looks ugly with small
                      segment count.
                '''

            indices[index] = index
            index += 1

        # duplicate first corner vertex to close the fan
        indices[count] = indices[1]
        # count+1 used to specify how many indices are used
        self.batch.set_data(vertices, count, indices, count + 1)
        free(vertices)
        free(indices)

    cdef object draw_arc(self, double cx, double cy, double rx, double ry,
                         double angle_start, double angle_end, int segments):
        cdef:
            double fx, fy, x, y
            double tangential_factor, radial_factor, theta
            list points

        # convert to radians
        angle_start *= 0.017453292519943295
        angle_end *= 0.017453292519943295

        # number of vertices for arc, including start & end
        theta = (angle_end - angle_start) / segments
        tangential_factor = tan(theta)
        radial_factor = cos(theta)

        # unit circle, scale later
        x = cos(angle_start)
        y = sin(angle_start)

        # array of length `segments`
        points = []

        for i in range(segments):
            real_x = cx + x * rx
            real_y = cy + y * ry
            points.append((real_x, real_y))

            fx = -y
            fy = x
            x += fx * tangential_factor
            y += fy * tangential_factor
            x *= radial_factor
            y *= radial_factor

        return points

    @property
    def segments(self):
        '''Property for getting/setting the number of segments for each corner.
        '''
        return self._segments

    @segments.setter
    def segments(self, value):
        self._segments = self._check_segments(value)
        self.flag_data_update()

    @property
    def radius(self):
        '''Corner radii of the rounded rectangle, defaults to [10,].
        '''
        return self._radius

    @radius.setter
    def radius(self, value):
        self._radius = self._check_radius(value)
        self.flag_data_update()




"""
Graphics section with antialiasing that uses a combination of AntiAliasingLine
and the target graphics Instruction, such as Rectangle, Ellipse,
RoundedRectangle, Triangle and Quad.

NOTE: Texture antialiasing is currently not supported. If a texture is defined
for any of the graphics with antialiasing, then antialiasing will be disabled.

The antialiasing is also disabled for graphics with "fixed" shapes, such as
Rectangle, RoundedRectangle and Ellipse through verification in
``too_small_for_antialiasing`` function. Reasons for it:

    - Drawing an antialiasing line on figures with very small dimensions does
    not bring great visual improvements. 

    - This reduces the code complexity in the `adjust_params` functions,
    which are used to adjust the size of these figures, and keep them
    proportional to the figures without antialiasing.

TODO: Use AntiAliasingLine as a sort of "alpha test" to enable texture
antialiasing. This will likely involve utilizing glBlendFunc in conjunction
with other functions. It would also involve creating custom instructions,
similar to the custom stencil instructions bellow, to ensure efficiency.
"""




"""
The functions below are extended versions of the radd, rinsert and rremove from
VertexInstruction, with the ability to add/remove more than one instruction set
(BindTexture + VertexInstruction) to/from a instruction group.
"""

cdef void radd_instructions(InstructionGroup ig, VertexInstruction target_graphic, AntiAliasingLine aa_line):
    cdef Instruction instr = target_graphic.texture_binding, aa_instr = target_graphic.texture_binding
    ig.children.append(target_graphic.texture_binding)
    ig.children.append(target_graphic)
    ig.children.append(aa_line.texture_binding)
    ig.children.append(aa_line)
    aa_instr.set_parent(ig)
    aa_line.set_parent(ig)
    instr.set_parent(ig)
    target_graphic.set_parent(ig)


cdef void rinsert_instructions(InstructionGroup ig, int index, VertexInstruction target_graphic, AntiAliasingLine aa_line):
    cdef Instruction instr = target_graphic.texture_binding, aa_instr = target_graphic.texture_binding
    cdef int index_adjust = 0 if index < 0 else 1
    ig.children.insert(index, target_graphic.texture_binding)
    ig.children.insert(index + 1 * index_adjust, target_graphic)
    ig.children.insert(index + 2 * index_adjust, aa_line.texture_binding)
    ig.children.insert(index + 3 * index_adjust, aa_line)
    aa_instr.set_parent(ig)
    aa_line.set_parent(ig)
    instr.set_parent(ig)
    target_graphic.set_parent(ig)


cdef void rremove_instructions(InstructionGroup ig, VertexInstruction target_graphic, AntiAliasingLine aa_line):
    cdef Instruction instr = target_graphic.texture_binding, aa_instr = target_graphic.texture_binding
    ig.children.remove(target_graphic.texture_binding)
    ig.children.remove(target_graphic)
    ig.children.remove(aa_line.texture_binding)
    ig.children.remove(aa_line)
    aa_instr.set_parent(None)
    aa_line.set_parent(None)
    instr.set_parent(None)
    target_graphic.set_parent(None)


cdef class AntiAliasingLine(VertexInstruction):
    """(internal) An instruction similar to SmoothLine, adjusted for antialiasing purposes.

    NOTE: AntiAliasingLine is not intended for public use, it was created and
    adjusted only for antialiasing purposes.

    Overview of behavior:

    - Its main purpose is to be drawn around other graphic instructions (such
    as RoundedRectangle, Ellipse, etc.) that do not have antialiasing.

    - When the alpha channel value of the active context is less than 1.0,
    stencil operations will be performed to prevent overlapping of alpha
    channel values (by default, drawing two overlapping graphics with an alpha
    channel of 0.5 would produce an alpha channel of 1.0 at their intersection).

    - The stencil instructions are based on the mask provided through the
    "stencil_mask" argument.

    - Points are filtered before being used to create vertices. If the number
    of valid points is less than 3, the list of points will be emptied and
    AntiAliasingLine will not be drawn. There is no reason to allow a value
    lower than 3 points here.

    - As it was designed to wrap around a graphic Instruction, it is closed by default.

    - The texture used, as well as the line width, have been defined through
    experimentation. Do not modify without extensive experimentation.

    """

    cdef list _points
    cdef float _width
    cdef int _close
    cdef int _use_stencil
    cdef Instruction _stencil_mask
    cdef Instruction _stencil_push
    cdef Instruction _stencil_use
    cdef Instruction _stencil_unuse
    cdef Instruction _stencil_pop

    def __init__(self, stencil_mask, **kwargs):
        super().__init__(**kwargs)
        self.batch.set_mode("triangles")
        self.close = int(bool(kwargs.get('close', 1)))  # closed by default
        self.points = kwargs.get('points', [])
        self.texture = self.premultiplied_texture()
        self._width = 2.5  # width defined through tests with the premultiplied texture
        self._stencil_push = None
        self._stencil_use = None
        self._stencil_unuse = None
        self._stencil_pop = None
        self._use_stencil = 0
        if isinstance(stencil_mask, Instruction):
            self._stencil_mask = stencil_mask  # the stencil mask
        else:
            raise TypeError(f"'stencil_mask' needs to be a graphics Instruction, got {type(stencil_mask)}")

    def premultiplied_texture(self):
        texture = Cache.get('kv.graphics.texture', 'antialiasing_line')
        if not texture:
            texture = Texture.create(size=(3, 1), colorfmt="rgba")
            texture.add_reload_observer(self._texture_reload_observer)
            self._texture_reload_observer(texture)
            Cache.append('kv.graphics.texture', 'antialiasing_line', texture)
        return texture

    cpdef _texture_reload_observer(self, texture):
        cdef bytes GRADIENT_DATA = (
            b"\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\x00")
        texture.blit_buffer(GRADIENT_DATA, colorfmt="rgba")

    cdef void radd(self, InstructionGroup ig):
        """Disabled because logic management is done on the radd of the target graphic (stencil_mask)"""
        pass

    cdef void rinsert(self, InstructionGroup ig, int index):
        """Disabled because logic management is done on the rinsert of the target graphic (stencil_mask)"""
        pass

    cdef void rremove(self, InstructionGroup ig):
        """Disabled because logic management is done on the rremove of the target graphic (stencil_mask)"""
        pass

    cdef void ensure_stencil(self):
        if self._stencil_push == None:
            self._stencil_push = StencilPush(clear_stencil=False)
            self._stencil_pop = StencilPop()
            self._stencil_use = StencilUse(op="greater")
            self._stencil_unuse = StencilUnUse()

    cdef int apply(self) except -1:
        cdef double alpha = getActiveContext()['color'][-1]
        self._use_stencil = alpha < 1
        if self._use_stencil:
            self.ensure_stencil()
            self._stencil_push.apply()
            self._stencil_mask.apply()
            self._stencil_use.apply()
            VertexInstruction.apply(self)
            self._stencil_unuse.apply()
            self._stencil_mask.apply()
            self._stencil_pop.apply()
        else:
            VertexInstruction.apply(self)
        return 0

    cdef void build(self):
        cdef:
            list p = self.points
            float width = self._width
            vertex_t *vertices = NULL
            unsigned short *indices = NULL
            double ax, ay, bx = 0., by = 0., cx = 0., cy = 0., last_angle = 0., angle, angle_diff
            double offset_x, offset_y, joint_offset_x, joint_offset_y
            int i, iv = 0, max_index, direction
            unsigned short vcount, icount, discarded_vcount = 3

        # AntiAliasingLine drawn will not be performed if the list of points
        # filtered by filtered_points is empty or has less than 3 points.
        if not p:
            self.batch.clear_data()
            return

        if self._close:
            discarded_vcount = 0

        icount = vcount = <unsigned short>int(9 * ((len(p) - 2) / 2) - discarded_vcount)

        vertices = <vertex_t *>malloc(vcount * sizeof(vertex_t))
        if vertices == NULL:
            raise MemoryError("vertices")

        indices = <unsigned short *>malloc(icount * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError("indices")

        if self._close:
            ax = p[-4]
            ay = p[-3]
            bx = p[0]
            by = p[1]
            cx = bx - ax
            cy = by - ay
            last_angle = atan2(cy, cx)

        max_index = len(p) - 2
        for i in range(0, max_index, 2):
            ax = p[i]
            ay = p[i + 1]
            bx = p[i + 2]
            by = p[i + 3]
            cx = bx - ax
            cy = by - ay
            angle = atan2(cy, cx)

            offset_x = width * sin(angle)
            offset_y = width * cos(angle)

            # fisrt triangle
            vertices[iv].x = <float>ax - offset_x
            vertices[iv].y = <float>ay + offset_y
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1
            vertices[iv].x = <float>bx + offset_x
            vertices[iv].y = <float>by - offset_y
            vertices[iv].s0 = 1
            vertices[iv].t0 = 0
            iv += 1
            vertices[iv].x = <float>ax + offset_x
            vertices[iv].y = <float>ay - offset_y
            vertices[iv].s0 = 1
            vertices[iv].t0 = 0
            iv += 1

            # second triangle
            vertices[iv].x = <float>ax - offset_x
            vertices[iv].y = <float>ay + offset_y
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1
            vertices[iv].x = <float>bx + offset_x
            vertices[iv].y = <float>by - offset_y
            vertices[iv].s0 = 1
            vertices[iv].t0 = 0
            iv += 1
            vertices[iv].x = <float>bx - offset_x
            vertices[iv].y = <float>by + offset_y
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1

            # miter joint code
            if i > 0 or self._close:
                joint_offset_x = width * sin(last_angle)
                joint_offset_y = width * cos(last_angle)

                angle_diff = (angle - last_angle)
                direction = -1 if - pi < angle_diff < 0 or angle_diff > pi else 1

                # miter joint triangle
                vertices[iv].x = <float>ax
                vertices[iv].y = <float>ay
                vertices[iv].s0 = 0.5
                vertices[iv].t0 = 0
                iv += 1
                vertices[iv].x = <float>ax + offset_x * direction
                vertices[iv].y = <float>ay - offset_y * direction
                vertices[iv].s0 = 1
                vertices[iv].t0 = 0
                iv += 1
                vertices[iv].x = <float>ax + joint_offset_x * direction
                vertices[iv].y = <float>ay - joint_offset_y * direction
                vertices[iv].s0 = 1
                vertices[iv].t0 = 0
                iv += 1

            last_angle = angle

        for i in range(icount):
            indices[i] = i

        self.batch.set_data(vertices, <int>vcount, indices, <int>icount)

        free(vertices)
        free(indices)

    cdef filtered_points(self, points):
        """Removes points where the x and y distances are less than 1px.

        If the points are too close, we must remove them for a few reasons:
        
        - Equal points generate an inconsistency in the generation of the
        miter joint. And dealing with them internally increases code
        complexity (unnecessarily).

        - Very close points (with distance less than 1px) have little
        relevance for antialiasing line drawing purposes. Furthermore,
        calculation inaccuracies can lead to the production of incorrect
        miter joints.

        - Fewer vertices to compute. By discarding the insignificant points
        we will also be saving computational resources and increasing the
        performance of building the antialiasing line.
        """
        cdef int index = 0
        cdef list p = points
        cdef double x1, x2, y1, y2

        # At least 3 points are required, otherwise we will return an empty
        # list, which means there are no valid points,
        # disabling AntiAliasingLine rendering.
        if len(p) < 6:
            return []

        while index < len(p) - 2:
            x1, y1 = p[index], p[index + 1]
            x2, y2 = p[index + 2], p[index + 3]
            if abs(x2 - x1) < 1.0 and abs(y2 - y1) < 1.0:
                del p[index + 2: index + 4]
            else:
                index += 2
        if abs(p[0] - p[-2]) < 1.0 and abs(p[1] - p[-1]) < 1.0:
            del p[:2]
        
        # If the amount of valid points is less than 3, then we will
        # return an empty list, to disable AntiAliasingLine rendering.
        return [] if len(p) < 6 else p

    @property
    def width(self):
        return self._width

    @property
    def points(self):
        return self._points
    
    @points.setter
    def points(self, points):
        if points and isinstance(points[0], (list, tuple)):
            points = list(itertools.chain(*points))
        else:
            points = list(points)
        points = self.filtered_points(points)
        if points and self.close:
            points += points[:2]
        self._points = points
        self.flag_data_update()
    
    @property
    def close(self):
        return self._close
    
    @close.setter
    def close(self, value):
        self._close = int(bool(value))
        self.flag_data_update()




cdef int has_texture_set(VertexInstruction instruction):
    if (instruction.texture and instruction.texture != instruction.default_texture) or instruction.source:
        return 1
    return 0


cdef int too_small_for_antialiasing(VertexInstruction instruction):
    if not isinstance(instruction, (SmoothRectangle, SmoothRoundedRectangle, SmoothEllipse)):
        raise NotImplementedError()

    return (-4 < instruction.size[0] < 4 or -4 < instruction.size[1] < 4)


cdef void adjust_params(VertexInstruction instruction, int delta):
        """Adjust the parameters that define the size of the drawing.
        This adjustment needs to be made before building the points, in order
        to compensate for the antialiasing line drawn around the contour of
        the figure.
        """
        if not isinstance(instruction, (SmoothRectangle, SmoothRoundedRectangle, SmoothEllipse)):
            raise NotImplementedError()

        cdef int sign_x, sign_y

        x, y = instruction.pos
        w, h = instruction.size

        sign_x = 1 if w < 0 else -1
        sign_y = 1 if h < 0 else -1

        x += delta * sign_x
        y += delta * sign_y
        w += delta * 2 * sign_x * -1
        h += delta * 2 * sign_y * -1

        instruction.pos = [x, y]
        instruction.size = [w, h]

        if isinstance(instruction, SmoothRoundedRectangle):
            instruction.radius = [(max(0, rx + delta), max(0, ry + delta)) for rx, ry in instruction.radius]




cdef class SmoothRoundedRectangle(RoundedRectangle):
    """RoundedRectangle with antialiasing.

    Its usage is the same as :class:`~kivy.graphics.vertex_instructions.RoundedRectangle`

    .. note::
        There is still no support for texture antialiasing. Therefore, if a
        texture is defined using either ``texture`` or ``source``,
        antialiasing will be disabled.

    .. versionadded:: 2.3.0

    """

    cdef AntiAliasingLine _antialiasing_line
    cdef public Texture default_texture

    def __init__(self, **kwargs):
        self._antialiasing_line = AntiAliasingLine(stencil_mask=self, close=1)
        RoundedRectangle.__init__(self, **kwargs)
        self.default_texture = self.texture

    cdef void radd(self, InstructionGroup ig):
        radd_instructions(ig, self, self._antialiasing_line)

    cdef void rinsert(self, InstructionGroup ig, int index):
        rinsert_instructions(ig, index, self, self._antialiasing_line)
    
    cdef void rremove(self, InstructionGroup ig):
        rremove_instructions(ig, self, self._antialiasing_line)

    cdef void build(self):
        if has_texture_set(self) or too_small_for_antialiasing(self):
            self._antialiasing_line.points = []
            RoundedRectangle.build(self)
        else:
            adjust_params(self, -1)
            RoundedRectangle.build(self)
            self._antialiasing_line.points = self._points
            adjust_params(self, 1)
    
    @property
    def antialiasing_line_points(self):
        return self._antialiasing_line.points


cdef class SmoothRectangle(Rectangle):
    """Rectangle with antialiasing.

    Its usage is the same as :class:`~kivy.graphics.vertex_instructions.Rectangle`

    .. note::
        There is still no support for texture antialiasing. Therefore, if a
        texture is defined using either ``texture`` or ``source``,
        antialiasing will be disabled.

    .. versionadded:: 2.3.0

    """

    cdef AntiAliasingLine _antialiasing_line
    cdef public Texture default_texture

    def __init__(self, **kwargs):
        self._antialiasing_line = AntiAliasingLine(stencil_mask=self, close=1)
        Rectangle.__init__(self, **kwargs)
        self.default_texture = self.texture

    cdef void radd(self, InstructionGroup ig):
        radd_instructions(ig, self, self._antialiasing_line)

    cdef void rinsert(self, InstructionGroup ig, int index):
        rinsert_instructions(ig, index, self, self._antialiasing_line)
    
    cdef void rremove(self, InstructionGroup ig):
        rremove_instructions(ig, self, self._antialiasing_line)

    cdef void build(self):
        if has_texture_set(self) or too_small_for_antialiasing(self):
            self._antialiasing_line.points = []
            Rectangle.build(self)
        else:
            adjust_params(self, -1)
            Rectangle.build(self)
            self._antialiasing_line.points = self._points
            adjust_params(self, 1)
    
    @property
    def antialiasing_line_points(self):
        return self._antialiasing_line.points


cdef class SmoothEllipse(Ellipse):
    """Ellipse with antialiasing.

    Its usage is the same as :class:`~kivy.graphics.vertex_instructions.Ellipse`

    .. note::
        There is still no support for texture antialiasing. Therefore, if a
        texture is defined using either ``texture`` or ``source``,
        antialiasing will be disabled.

    .. versionadded:: 2.3.0

    """

    cdef AntiAliasingLine _antialiasing_line
    cdef public Texture default_texture

    def __init__(self, **kwargs):
        self._antialiasing_line = AntiAliasingLine(stencil_mask=self, close=1)
        Ellipse.__init__(self, **kwargs)
        self.default_texture = self.texture

    cdef void radd(self, InstructionGroup ig):
        radd_instructions(ig, self, self._antialiasing_line)

    cdef void rinsert(self, InstructionGroup ig, int index):
        rinsert_instructions(ig, index, self, self._antialiasing_line)
    
    cdef void rremove(self, InstructionGroup ig):
        rremove_instructions(ig, self, self._antialiasing_line)

    cdef void build(self):
        cdef list ellipse_center = []

        if has_texture_set(self) or too_small_for_antialiasing(self):
            self._antialiasing_line.points = []
            Ellipse.build(self)
        else:
            adjust_params(self, -1)
            Ellipse.build(self)
            ellipse_center = [self.x + self.w / 2, self.y + self.h / 2]
            self._antialiasing_line.points = self._points + ellipse_center
            adjust_params(self, 1)

    @property
    def antialiasing_line_points(self):
        return self._antialiasing_line.points


cdef class SmoothQuad(Quad):
    """Quad with antialiasing.

    Its usage is the same as :class:`~kivy.graphics.vertex_instructions.Quad`

    .. note::
        There is still no support for texture antialiasing. Therefore, if a
        texture is defined using either ``texture`` or ``source``,
        antialiasing will be disabled.

    .. versionadded:: 2.3.0

    """

    cdef AntiAliasingLine _antialiasing_line
    cdef public Texture default_texture

    def __init__(self, **kwargs):
        self._antialiasing_line = AntiAliasingLine(stencil_mask=self, close=1)
        Quad.__init__(self, **kwargs)
        self.default_texture = self.texture

    cdef void radd(self, InstructionGroup ig):
        radd_instructions(ig, self, self._antialiasing_line)

    cdef void rinsert(self, InstructionGroup ig, int index):
        rinsert_instructions(ig, index, self, self._antialiasing_line)
    
    cdef void rremove(self, InstructionGroup ig):
        rremove_instructions(ig, self, self._antialiasing_line)

    cdef void build(self):
        if has_texture_set(self):
            self._antialiasing_line.points = []
            Quad.build(self)
        else:
            # adjust_params(self, -1)
            Quad.build(self)
            self._antialiasing_line.points = self._points
            # adjust_params(self, 1)
    
    @property
    def antialiasing_line_points(self):
        return self._antialiasing_line.points


cdef class SmoothTriangle(Triangle):
    """Triangle with antialiasing.

    Its usage is the same as :class:`~kivy.graphics.vertex_instructions.Triangle`

    .. note::
        There is still no support for texture antialiasing. Therefore, if a
        texture is defined using either ``texture`` or ``source``,
        antialiasing will be disabled.

    .. versionadded:: 2.3.0

    """

    cdef AntiAliasingLine _antialiasing_line
    cdef public Texture default_texture

    def __init__(self, **kwargs):
        self._antialiasing_line = AntiAliasingLine(stencil_mask=self, close=1)
        Triangle.__init__(self, **kwargs)
        self.default_texture = self.texture

    cdef void radd(self, InstructionGroup ig):
        radd_instructions(ig, self, self._antialiasing_line)

    cdef void rinsert(self, InstructionGroup ig, int index):
        rinsert_instructions(ig, index, self, self._antialiasing_line)
    
    cdef void rremove(self, InstructionGroup ig):
        rremove_instructions(ig, self, self._antialiasing_line)

    cdef void build(self):
        if has_texture_set(self):
            self._antialiasing_line.points = []
            Triangle.build(self)
        else:
            # adjust_params(self, -1)
            Triangle.build(self)
            self._antialiasing_line.points = self._points[:6]
            # adjust_params(self, 1)
        
    @property
    def antialiasing_line_points(self):
        return self._antialiasing_line.points
