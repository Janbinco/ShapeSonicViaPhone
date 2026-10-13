Make a 3D implementation of ShapeSonic that works on iOS (iPhone or iPad). Use ARKit to obtain the iPhone/iPad's world-space coordinates. Those world-space coordinates can be used to transform multi-touch interactions on the screen into 3D points in space, which is the input ShapeSonic needs. The paper describing ShapeSonic is ``../paper/main.tex`. A 2D implementation for the web is in `../demo`. The sounds are in the `../demo/audio` directory.

UI:

* A pop-up menu on the screen should let the user choose from demo shapes (`models/*.obj`) or load a 3D shape (as an OBJ and possibly other formats). That should be enough to rasterize an SDF. (Consider an octree SDF to limit memory consumption.) Detect corners and edges from the OBJ.

* A toggle to show the shape. By default the shape should be hidden. (Its name should only be visible inside the pop-up menu.) Visualize detected corners and edges.

* A toggle so that the first 5 touches are from one hand and the second from the other, rather than dividing the screen.

We want the lowest-latency interactions.

Save and maintain a document describing the implementation's design and architecture.
